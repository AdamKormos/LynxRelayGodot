extends Node

##
## Lynx Relay Client
## Autoload client for Lynx API sync flow
##
## Recommended Autoload name:
## LynxRelay
##
## Main method:
##   await LynxRelay.sync_relay("devtest")
##
## This fetches the relay counter AND automatically asks the server whether
## a reward is claimable. You do not call claim_relay separately anymore.
##
## Important behavior:
## - If a reward is pending acknowledgement, sync_relay() STILL fetches the
##   latest public relay value with GET /v1/relays/{id}.
## - It does NOT perform another token-changing claim/sync until you call
##   ack_claim(relay_id).
## - This means the UI can keep showing the newest value/target/progress even
##   while an old reward is waiting to be accepted/saved.
##
## Dynamic target fields expected from the backend:
## - target: current cumulative target threshold, e.g. 220 for goal #2
## - target_multiplier: growth multiplier, e.g. 1.2
## - previous_target: previous cumulative threshold, e.g. 100
## - next_required: amount needed for the current stage, e.g. 120
## - stage_progress: progress inside the current stage, 0.0-1.0


# -------------------------------------------------------------------
# CONFIG
# -------------------------------------------------------------------

## Server's base URL
const BASE_URL := "https://api.lynxrelay.space"

# Fill these in for your game.
## The Identifier you specified for your game.
const GAME_ID := ""
## GAME_KEY is the runtime game key, not the private Game Admin Password.
## Never put the Game Admin Password in a Godot project or exported build.
const GAME_KEY := ""

## The events used in your game. Fill this list appropriately.
## These are baselined on first install, meaning that
## a new install starts from the current server completion_version,
## so the player will NOT receive old rewards from before first launch
## (e.g. if an event has been completed 4 times, and a player plays
## the first time, they do NOT get 4 rewards by default).
const TRACKED_RELAYS := [
	"devtest"
]

## Path for the installation file. See _save_installation_file() too.
const INSTALLATION_SAVE_PATH := "user://lynx_relay_installation.json"

## Minimum time between real sync HTTP requests for the same relay.
## Calls inside this window return the last cached sync result instead.
const SYNC_CACHE_MS := 5000

## Increment requests are queued so accidental per-frame calls are serialized safely.
## This short delay lets same-frame triggers enter the FIFO queue before the worker starts.
## Queue items are sent one-by-one; amounts are never merged.
const INCREMENT_BATCH_FLUSH_DELAY_SECONDS := 0.25

## Fallback retry delay used when a transient request failure does not include retry_after_seconds.
const DEFAULT_INCREMENT_RETRY_DELAY_SECONDS := 5.0


# -------------------------------------------------------------------
# SIGNALS
# -------------------------------------------------------------------

## Emitted after setup() finishes successfully.
signal setup_completed
## Emitted when setup() cannot register/load/recover the local installation.
signal setup_failed(message: String, code: String)

## Emitted whenever a relay state was successfully read.
## relay_state contains the latest public counter/target/progress data.
## claim contains the current reward receipt, or a zero-count/read-only claim.
signal sync_completed(
	relay_id: String,
	relay_state: Dictionary,
	claim: Dictionary
)

## Emitted when the server approved one or more new rewards.
## The game should grant/save the reward, then call ack_claim(relay_id).
## from_pending is true when the same unacknowledged reward is being replayed.
signal reward_available(
	relay_id: String,
	completion_count: int,
	from_version: int,
	to_version: int,
	from_pending: bool
)

## Emitted when the local claimed_versions mirror advances for a relay.
## This is useful for UI/debugging, but the encrypted state_token is still authoritative.
signal claimed_version_updated(
	relay_id: String,
	claimed_version: int
)

## Emitted after ack_claim() advances the local state token for a pending reward.
signal claim_acknowledged(
	relay_id: String,
	claimed_version: int
)

## Emitted when any API request fails.
## result contains status/code/error and any parsed response body.
signal request_failed(
	action: String,
	relay_id: String,
	result: Dictionary
)

## Emitted on authorization/subscription failures such as 401, 402, or 403.
signal game_access_rejected(code: String, message: String)

## Emitted when this local installation starts an increment request.
## Useful for UI feedback and for distinguishing local unlocks from remote community unlocks.
signal increment_started(relay_id: String, amount: int)

## Emitted when an increment was added to the local batch queue.
signal increment_queued(relay_id: String, amount: int, pending_amount: int)

## Emitted when a queued increment batch starts sending to the backend.
signal increment_flush_started(relay_id: String, amount: int)

## Emitted when a queued increment could not be sent yet but was kept for a later retry.
signal increment_retry_scheduled(relay_id: String, amount: int, retry_after_seconds: float, result: Dictionary)

## Emitted after this local installation successfully flushed an increment batch.
signal increment_completed(relay_id: String, amount: int, relay_state: Dictionary, result: Dictionary)

## Emitted when this local installation attempted to increment a relay but the request failed permanently.
signal increment_failed(relay_id: String, amount: int, result: Dictionary)


# -------------------------------------------------------------------
# STATE
# -------------------------------------------------------------------

## Server-generated installation identifier stored locally after first registration.
var installation_id: String = ""

## Secret per-installation token used to authenticate this local player install.
var installation_token: String = ""

## Rolling encrypted state token returned by the server.
## This stores the authoritative reward claim state in a tamper-resistant form.
var state_token: String = ""

## Pending claims are rewards the server already approved, but the game
## has not yet acknowledged as saved locally.
var pending_claims: Dictionary = {}

## Best-effort local mirror of the version the client has advanced to,
## retrieved upon acknowledging a reward claim.
## Source of truth is still the encrypted server state_token.
## This is useful for UI/debug/save logic:
## LynxRelay.get_client_claimed_version("devtest")
var claimed_versions: Dictionary = {}

## True after setup() has completed successfully.
var is_setup: bool = false

## Prevents multiple simultaneous setup() calls from registering/recovering at once.
var setup_in_progress: bool = false

## Last successful sync result per relay. Used to prevent spammy HTTP sync calls.
var _sync_cache_by_relay: Dictionary = {}

## Tick time of each cached sync result.
var _sync_cache_time_by_relay: Dictionary = {}

## Highest relay state seen by this client per relay.
## This prevents older in-flight sync responses from moving UI counters backwards
## after a newer local increment response has already been confirmed.
var _latest_relay_state_by_relay: Dictionary = {}

## True while a real HTTP sync is already running for a relay.
## Extra sync_relay() calls will join the result instead of starting another request.
var _sync_in_flight_by_relay: Dictionary = {}

## Pending local increment requests, keyed by relay id.
## Each entry is sent as its own backend request; values are never merged.
var _increment_queue_by_relay: Dictionary = {}

## True when a delayed queue drain has already been scheduled for a relay.
var _increment_flush_scheduled_by_relay: Dictionary = {}

## True while the single queue worker is draining a relay's increment queue.
var _increment_flush_in_flight_by_relay: Dictionary = {}

## Last completed increment result for callers that joined an already-running flush.
var _increment_last_flush_result_by_relay: Dictionary = {}

## Earliest tick time when the next retry is allowed after a transient/rate-limit error.
var _increment_retry_not_before_ms_by_relay: Dictionary = {}


## Starts setup automatically when this Autoload enters the scene tree.
## Calls are still safe to repeat because setup() is guarded by is_setup/setup_in_progress.
func _ready() -> void:
	setup()


# -------------------------------------------------------------------
# SETUP
# -------------------------------------------------------------------

## Initializes the plugin.
func setup() -> bool:
	# If setup already succeeded earlier, there is nothing else to do.
	if is_setup:
		return true
	
	# If another caller already started setup, wait for it instead of duplicating the setup request.
	if setup_in_progress:
		while setup_in_progress:
			await get_tree().process_frame
		return is_setup
	
	setup_in_progress = true
	
	# Load existing installation credentials and pending rewards from disk.
	_load_installation_file()
	
	var result: Dictionary
	
	# If no complete local installation exists, create one on the server.
	# A new installation also resets event reward counters for the player.
	if installation_id.is_empty() or installation_token.is_empty() or state_token.is_empty():
		result = await register_installation()
		
		if not result.get("ok", false):
			setup_in_progress = false
			setup_failed.emit(
				str(result.get("error", "Installation registration failed")),
				str(result.get("code", "registration_failed"))
			)
			return false
	
	is_setup = true
	setup_in_progress = false
	setup_completed.emit()
	return true


## Used when players launch the game for the first time.
func register_installation() -> Dictionary:
	var headers := _game_headers()
	headers.append("Content-Type: application/json")
	
	var payload := {
		"tracked_relays": TRACKED_RELAYS
	}
	
	# Registration returns installation credentials, initial state_token,
	# and baseline claim versions for TRACKED_RELAYS.
	var result := await _send_json_request(
		_url("/v1/installations/register"),
		HTTPClient.METHOD_POST,
		headers,
		payload
	)
	
	if not result.get("ok", false):
		return result
	
	var data: Dictionary = result["data"]
	
	installation_id = str(data.get("installation_id", ""))
	installation_token = str(data.get("installation_token", ""))
	state_token = str(data.get("state_token", ""))
	pending_claims.clear()
	
	# Mirror the server baseline locally for UI/debug convenience.
	var baseline_claims: Variant = data.get("baseline_claims", {})
	if baseline_claims is Dictionary:
		_update_claimed_versions_from_dictionary(baseline_claims)
	
	_save_installation_file()
	
	return {
		"ok": true,
		"data": data
	}


## Requests the latest server-side state token for this installation.
## This is used when the local token expired or became stale.
## Recovery is blocked while a pending reward exists, to avoid losing it,
## otherwise, if the token is recovered, unclaimed rewards become invalid.
func recover_state() -> Dictionary:
	# Recovery requires an already registered local installation.
	if installation_id.is_empty() or installation_token.is_empty():
		return {
			"ok": false,
			"status": 0,
			"code": "missing_installation",
			"error": "No installation exists yet."
		}
	
	# Do not recover over a pending reward, because that could discard an
	# approved reward before the game has safely saved it.
	if not pending_claims.is_empty():
		return {
			"ok": false,
			"status": 0,
			"code": "pending_claim_exists",
			"error": "Cannot recover state while a reward claim is pending acknowledgement."
		}
	
	# Ask the server for the latest valid rolling state token.
	var result := await _send_json_request(
		_url("/v1/installations/state"),
		HTTPClient.METHOD_GET,
		_game_and_installation_headers()
	)
	
	if not result.get("ok", false):
		return result
	
	var data: Dictionary = result["data"]
	state_token = str(data.get("state_token", ""))
	_save_installation_file()
	
	return {
		"ok": true,
		"data": data
	}


# -------------------------------------------------------------------
# MAIN API
# -------------------------------------------------------------------

## Standard function to get the latest event state.
##
## If there is no pending reward:
## - Calls POST /sync
## - Fetches current relay state
## - Auto-claims reward if available
##
## If this relay already has a pending reward:
## - Calls GET /relays/{id}
## - Emits sync_completed with the LATEST relay_state
## - Re-emits reward_available from the pending claim
## - Does NOT advance/modify state_token
##
## If another relay has a pending reward:
## - Calls GET /relays/{id}
## - Emits sync_completed with latest relay_state
## - Returns ok with blocked_by_pending_claim=true
## - Does NOT claim new rewards until the pending reward is acked
func sync_relay(relay_id: String, force: bool = false) -> Dictionary:
	var setup_ok := await setup()
	
	if not setup_ok:
		return {
			"ok": false,
			"status": 0,
			"code": "setup_failed",
			"error": "Relay setup failed."
		}
	
	# Normal UI/timer refreshes should not hit HTTP more than once per relay per second.
	# Cached returns still emit sync_completed so the UI can update through the same path.
	if not force:
		var cached := _get_cached_sync_result(relay_id)
		if not cached.is_empty():
			_emit_sync_completed_from_cached_result(relay_id, cached)
			return cached
		
		# If an HTTP sync is already running for this relay, wait for it and reuse its cache.
		# This prevents request bursts like 5 parallel sync_relay() calls in the same frame.
		if bool(_sync_in_flight_by_relay.get(relay_id, false)):
			while bool(_sync_in_flight_by_relay.get(relay_id, false)):
				await get_tree().process_frame
			
			cached = _get_cached_sync_result(relay_id)
			if not cached.is_empty():
				cached["in_flight_joined"] = true
				_emit_sync_completed_from_cached_result(relay_id, cached)
				return cached
	else:
		# Force refresh bypasses the cache, but still waits for an already-running
		# request to finish so we do not create avoidable parallel HTTP syncs.
		while bool(_sync_in_flight_by_relay.get(relay_id, false)):
			await get_tree().process_frame
	
	_sync_in_flight_by_relay[relay_id] = true
	var result: Dictionary = await _sync_relay_uncached(relay_id)
	_sync_in_flight_by_relay.erase(relay_id)
	
	if result.get("ok", false):
		_store_sync_cache(relay_id, result)
	
	return result


## Performs the actual sync logic without plugin-side cache/throttle.
func _sync_relay_uncached(relay_id: String) -> Dictionary:
	# Important fix:
	# Pending reward must NOT block reading the latest public counter.
	# The old code returned the cached pending response, so value could stay at
	# 905 even if the server was already at 955.
	if pending_claims.has(relay_id):
		return await _sync_relay_read_latest_with_pending_reward(relay_id)
	
	# If another relay has a pending claim, we still allow reading this relay's
	# latest public state, but we do not perform a token-changing sync/claim.
	if not pending_claims.is_empty():
		return await _sync_relay_read_only_blocked_by_other_pending(relay_id)
	
	# If the file exists but state_token is missing, try to recover it safely.
	if state_token.is_empty():
		var recovered := await recover_state()
		
		if not recovered.get("ok", false):
			request_failed.emit("sync", relay_id, recovered)
			return recovered
	
	# Perform the main sync. This can also approve rewards.
	var result := await _sync_relay_with_id(relay_id, _generate_request_id())
	
	if not result.get("ok", false):
		var code := str(result.get("code", ""))
		
		# Retry once with a fresh token if the local token is outdated.
		if code == "state_token_expired" or code == "stale_state_token":
			var recovered := await recover_state()
			
			if recovered.get("ok", false):
				result = await _sync_relay_with_id(relay_id, _generate_request_id())
		
		if not result.get("ok", false):
			request_failed.emit("sync", relay_id, result)
			return result
	
	var data: Dictionary = result["data"]
	var relay_state: Dictionary = data.get("relay", {})
	var claim: Dictionary = data.get("claim", {})
	
	# completion_count > 0 means the server approved a reward.
	var completion_count := int(claim.get("completion_count", 0))
	var new_state_token := str(claim.get("new_state_token", ""))
	
	if completion_count > 0:
		# We do not advance local state_token until the game saved the reward.
		# Instead, the claim is marked as "pending".
		pending_claims[relay_id] = {
			"response": data,
			"new_state_token": new_state_token
		}
		_save_installation_file()
		
		relay_state = _remember_relay_state(relay_id, relay_state)
		sync_completed.emit(relay_id, relay_state, claim)
		_emit_reward_available(relay_id, claim, false)
	else:
		# No reward can be lost (because completion_count is <= 0),
		# so safely advance the rolling token now.
		if not new_state_token.is_empty():
			state_token = new_state_token
			_update_claimed_version_from_claim(relay_id, claim)
			_save_installation_file()
		
		relay_state = _remember_relay_state(relay_id, relay_state)
		sync_completed.emit(relay_id, relay_state, claim)

	return result

# Backward-compatible alias. Prefer sync_relay().
## Legacy alias kept for older code.
## New integrations should call sync_relay(), because sync also returns relay state.
func claim_relay(relay_id: String) -> Dictionary:
	return await sync_relay(relay_id)


## Performs synchronization on every tracked relay object.
func sync_tracked_relays() -> Dictionary:
	var results := {}
	
	for relay_id in TRACKED_RELAYS:
		var result := await sync_relay(str(relay_id))
		results[str(relay_id)] = result
	
	return results


## Validates that a reward has been accepted/saved by the game.
func ack_claim(relay_id: String) -> bool:
	if not pending_claims.has(relay_id):
		return false
	
	var pending: Dictionary = pending_claims[relay_id]
	var new_token := str(pending.get("new_state_token", ""))
	
	if new_token.is_empty():
		push_warning("Pending Lynx claim has no new_state_token.")
		return false
	
	var pending_response: Dictionary = pending.get("response", {})
	var pending_claim: Dictionary = pending_response.get("claim", {})
	
	state_token = new_token
	_update_claimed_version_from_claim(relay_id, pending_claim)
	pending_claims.erase(relay_id)
	invalidate_sync_cache(relay_id)
	_save_installation_file()
	
	var claimed_version := get_client_claimed_version(relay_id)
	claim_acknowledged.emit(relay_id, claimed_version)
	
	return true


func get_relay(relay_id: String) -> Dictionary:
	# Public read-only endpoint. Does not touch state_token.
	var result := await _send_json_request(
		_url("/v1/relays/" + relay_id.uri_encode()),
		HTTPClient.METHOD_GET
	)
	
	if not result.get("ok", false):
		request_failed.emit("get", relay_id, result)
	
	return result


## Queues an event counter increment.
##
## This intentionally uses a simple FIFO queue instead of amount batching.
## Every gameplay trigger becomes one queued backend increment request. This keeps
## backend max_increment validation meaningful and avoids batch state bugs.
##
## The main counter remains server-authoritative. The UI should update the confirmed
## counter only from increment_completed/sync_completed responses.
func increment_relay(relay_id: String, amount: int = 1, flush_immediately: bool = false) -> Dictionary:
	if amount <= 0:
		var invalid_amount_result := {
			"ok": false,
			"status": 0,
			"code": "invalid_amount",
			"error": "Increment amount must be positive."
		}
		increment_failed.emit(relay_id, amount, invalid_amount_result)
		return invalid_amount_result
	
	# Fire immediately so UI/gameplay can show non-authoritative feedback without
	# changing the main server counter.
	increment_started.emit(relay_id, amount)
	
	var queue := _get_increment_queue(relay_id)
	queue.append(amount)
	_increment_queue_by_relay[relay_id] = queue
	increment_queued.emit(relay_id, amount, _sum_increment_queue(queue))
	
	_start_increment_queue_worker(
		relay_id,
		0.0 if flush_immediately else INCREMENT_BATCH_FLUSH_DELAY_SECONDS
	)
	
	return {
		"ok": true,
		"status": 0,
		"queued": true,
		"relay_id": relay_id,
		"amount": amount,
		"pending_amount": _sum_increment_queue(queue),
		"pending_count": queue.size(),
		"flush_delay_seconds": 0.0 if flush_immediately else INCREMENT_BATCH_FLUSH_DELAY_SECONDS
	}


## Backward-compatible manual flush entry point.
## It starts the same single-owner queue worker used by increment_relay().
func flush_pending_increment(relay_id: String) -> Dictionary:
	var queue := _get_increment_queue(relay_id)
	if queue.is_empty():
		return {
			"ok": true,
			"status": 0,
			"noop": true,
			"relay_id": relay_id
		}
	
	_start_increment_queue_worker(relay_id, 0.0)
	return {
		"ok": true,
		"status": 0,
		"queued": true,
		"relay_id": relay_id,
		"pending_amount": _sum_increment_queue(queue),
		"pending_count": queue.size()
	}


func _start_increment_queue_worker(relay_id: String, initial_delay_seconds: float) -> void:
	if bool(_increment_flush_in_flight_by_relay.get(relay_id, false)):
		return
	
	if bool(_increment_flush_scheduled_by_relay.get(relay_id, false)):
		return
	
	_increment_flush_scheduled_by_relay[relay_id] = true
	call_deferred("_increment_queue_worker", relay_id, maxf(0.0, initial_delay_seconds))


func _increment_queue_worker(relay_id: String, initial_delay_seconds: float) -> void:
	if initial_delay_seconds > 0.0:
		await get_tree().create_timer(initial_delay_seconds).timeout
	
	_increment_flush_scheduled_by_relay.erase(relay_id)
	
	if bool(_increment_flush_in_flight_by_relay.get(relay_id, false)):
		return
	
	_increment_flush_in_flight_by_relay[relay_id] = true
	
	var setup_ok := await setup()
	if not setup_ok:
		var failed_queue := _get_increment_queue(relay_id)
		_increment_queue_by_relay.erase(relay_id)
		_increment_flush_in_flight_by_relay.erase(relay_id)
		var failed_amount := _sum_increment_queue(failed_queue)
		if failed_amount > 0:
			var setup_fail_result := {
				"ok": false,
				"status": 0,
				"code": "setup_failed",
				"error": "Relay setup failed before increment flush."
			}
			increment_failed.emit(relay_id, failed_amount, setup_fail_result)
		return
	
	while not _get_increment_queue(relay_id).is_empty():
		var now_ms := Time.get_ticks_msec()
		var retry_not_before_ms := int(_increment_retry_not_before_ms_by_relay.get(relay_id, 0))
		if retry_not_before_ms > now_ms:
			var wait_seconds := float(retry_not_before_ms - now_ms) / 1000.0
			var retry_result := {
				"ok": true,
				"status": 0,
				"queued_for_retry": true,
				"relay_id": relay_id,
				"pending_amount": _sum_increment_queue(_get_increment_queue(relay_id)),
				"pending_count": _get_increment_queue(relay_id).size(),
				"retry_after_seconds": wait_seconds
			}
			increment_retry_scheduled.emit(
				relay_id,
				_sum_increment_queue(_get_increment_queue(relay_id)),
				wait_seconds,
				retry_result
			)
			await get_tree().create_timer(wait_seconds).timeout
			continue
		
		var queue := _get_increment_queue(relay_id)
		if queue.is_empty():
			break
		
		var amount := int(queue.pop_front())
		_increment_queue_by_relay[relay_id] = queue
		
		increment_flush_started.emit(relay_id, amount)
		var result := await _send_increment_request(relay_id, amount)
		_increment_last_flush_result_by_relay[relay_id] = result.duplicate(true)
		
		if not result.get("ok", false):
			if _is_retryable_increment_result(result):
				# Put the same item back to the front. This is not batching: it is
				# the exact request that failed retryably.
				queue = _get_increment_queue(relay_id)
				queue.push_front(amount)
				_increment_queue_by_relay[relay_id] = queue
				var retry_after_seconds := _get_increment_retry_after_seconds(result)
				_increment_retry_not_before_ms_by_relay[relay_id] = Time.get_ticks_msec() + int(retry_after_seconds * 1000.0)
				result["queued_for_retry"] = true
				result["retry_after_seconds"] = retry_after_seconds
				request_failed.emit("increment", relay_id, result)
				increment_retry_scheduled.emit(
					relay_id,
					_sum_increment_queue(queue),
					retry_after_seconds,
					result
				)
				continue
			
			# Permanent failure: drop only this one queued item. Later queued
			# increments still get a chance instead of locking the queue forever.
			request_failed.emit("increment", relay_id, result)
			increment_failed.emit(relay_id, amount, result)
			continue
		
		_increment_retry_not_before_ms_by_relay.erase(relay_id)
		invalidate_sync_cache(relay_id)
		var relay_state := _extract_relay_state_from_increment_result(result)
		
		if not relay_state.is_empty():
			_store_sync_cache(relay_id, {
				"ok": true,
				"status": int(result.get("status", 200)),
				"data": relay_state
			})
			relay_state = _remember_relay_state(relay_id, relay_state)
			increment_completed.emit(relay_id, amount, relay_state, result)
			_maybe_sync_for_new_reward(relay_id, relay_state)
		else:
			increment_completed.emit(relay_id, amount, {}, result)
		
		# Yield one frame between queued requests so UI/signals can process and
		# rapid gameplay does not freeze the frame.
		await get_tree().process_frame
	
	_increment_flush_in_flight_by_relay.erase(relay_id)
	
	# If an increment arrived exactly while clearing the worker flag, start again.
	if not _get_increment_queue(relay_id).is_empty():
		_start_increment_queue_worker(relay_id, INCREMENT_BATCH_FLUSH_DELAY_SECONDS)


func _get_increment_queue(relay_id: String) -> Array:
	var existing: Variant = _increment_queue_by_relay.get(relay_id, [])
	if existing is Array:
		return existing.duplicate()
	return []


func _sum_increment_queue(queue: Array) -> int:
	var total := 0
	for item in queue:
		total += int(item)
	return total


func _send_increment_request(relay_id: String, amount: int) -> Dictionary:
	var headers := _game_headers()
	headers.append("Content-Type: application/json")
	headers.append("Idempotency-Key: " + _generate_request_id())
	
	var payload := {
		"amount": amount,
		"client_id": installation_id
	}
	
	return await _send_json_request(
		_url("/v1/relays/" + relay_id.uri_encode() + "/increment"),
		HTTPClient.METHOD_POST,
		headers,
		payload
	)


func _is_retryable_increment_result(result: Dictionary) -> bool:
	var status := int(result.get("status", 0))
	return status == 0 or status == 429 or status >= 500


func _get_increment_retry_after_seconds(result: Dictionary) -> float:
	var retry_after := float(result.get("retry_after_seconds", 0.0))
	if retry_after <= 0.0:
		retry_after = float(result.get("retry_after", 0.0))
	
	var body: Variant = result.get("data", {})
	if retry_after <= 0.0 and body is Dictionary:
		retry_after = float(body.get("retry_after_seconds", body.get("retry_after", 0.0)))
	
	if retry_after <= 0.0:
		retry_after = DEFAULT_INCREMENT_RETRY_DELAY_SECONDS
	return maxf(1.0, retry_after)


func _maybe_sync_for_new_reward(relay_id: String, relay_state: Dictionary) -> void:
	# Increment responses update the visible counter immediately. A token-changing
	# sync is only needed right away when a new completion version may have become
	# claimable; otherwise the 5-second passive sync will refresh normal state.
	var completion_version := int(relay_state.get("completion_version", 0))
	if completion_version <= get_client_claimed_version(relay_id):
		return
	
	if pending_claims.has(relay_id):
		return
	
	call_deferred("_deferred_reward_sync", relay_id)


func _deferred_reward_sync(relay_id: String) -> void:
	await get_tree().process_frame
	await sync_relay(relay_id, true)


## Returns true if this relay has a server-approved reward waiting for ack_claim().
func has_pending_claim(relay_id: String) -> bool:
	return pending_claims.has(relay_id)


## Returns true if any relay currently has an unacknowledged reward.
func has_any_pending_claim() -> bool:
	return not pending_claims.is_empty()


## Returns a deep copy of the pending claim data for a relay.
## Returns an empty Dictionary if nothing is pending.
func get_pending_claim(relay_id: String) -> Dictionary:
	if not pending_claims.has(relay_id):
		return {}
	return pending_claims[relay_id].duplicate(true)


## Returns the relay IDs that currently have pending rewards.
func get_pending_claim_ids() -> Array:
	return pending_claims.keys()


## Returns the local mirror of the highest claimed version for this relay.
## This is updated from baseline, zero-reward syncs, and ack_claim().
func get_client_claimed_version(relay_id: String) -> int:
	return int(claimed_versions.get(relay_id, 0))


## Returns a copy of all locally mirrored claimed versions.
func get_all_client_claimed_versions() -> Dictionary:
	return claimed_versions.duplicate(true)


## Convenience helper that reads only the public relay value.
## Returns 0 if the request fails.
func get_relay_value(relay_id: String) -> int:
	var result := await get_relay(relay_id)
	if not result.get("ok", false):
		return 0
	
	return int(result["data"].get("value", 0))


## Convenience helper that reads only the public completion_version.
## Returns 0 if the request fails.
func get_completion_version(relay_id: String) -> int:
	var result := await get_relay(relay_id)
	if not result.get("ok", false):
		return 0
	
	return int(result["data"].get("completion_version", 0))


func _extract_relay_state_from_sync_result(sync_result: Dictionary) -> Dictionary:
	if not sync_result.get("ok", false):
		return {}
	
	var data: Variant = sync_result.get("data", {})
	if not (data is Dictionary):
		return {}
	
	var data_dict: Dictionary = data
	if data_dict.has("relay") and data_dict["relay"] is Dictionary:
		return data_dict["relay"].duplicate(true)
	
	# get_relay-shaped fallback.
	return data_dict.duplicate(true)


func _extract_relay_state_from_increment_result(increment_result: Dictionary) -> Dictionary:
	if not increment_result.get("ok", false):
		return {}
	
	var data: Variant = increment_result.get("data", {})
	if not (data is Dictionary):
		return {}
	
	var data_dict: Dictionary = data
	
	# POST /increment currently returns { state = relay_state, ... }.
	if data_dict.has("state") and data_dict["state"] is Dictionary:
		return data_dict["state"].duplicate(true)
	
	# Keep these fallbacks so older/staging backends or manually mocked responses
	# still update the UI instead of silently dropping the confirmed increment.
	if data_dict.has("relay") and data_dict["relay"] is Dictionary:
		return data_dict["relay"].duplicate(true)
	
	if data_dict.has("value") or data_dict.has("target") or data_dict.has("completion_version"):
		return data_dict.duplicate(true)
	
	return {}


## Returns the currently displayed cumulative target from a relay_state.
## With dynamic growth, this is not always the original base target.
## Example: target_multiplier=1.2 and completion_version=1 -> the current cumulative target may be 220.
func get_goal_target_from_state(relay_state: Dictionary) -> int:
	return int(relay_state.get("target", 0))


## Returns the previous completed cumulative threshold from a relay_state.
## Example: for goal #2 this is usually the goal #1 target.
func get_goal_previous_target_from_state(relay_state: Dictionary) -> int:
	return int(relay_state.get("previous_target", 0))


## Returns the amount required for the current goal stage.
## Example: if previous_target=100 and target=220, goal #2 requires 120 more.
func get_goal_next_required_from_state(relay_state: Dictionary) -> int:
	return int(relay_state.get("next_required", 0))


## Returns progress inside the current goal stage, not overall value / target.
func get_goal_stage_progress_from_state(relay_state: Dictionary) -> float:
	return float(relay_state.get("stage_progress", 0.0))


## Deletes the local installation state.
## Use only for testing, because it makes this device register as a new install.
func clear_local_installation_for_testing_only() -> void:
	installation_id = ""
	installation_token = ""
	state_token = ""
	pending_claims.clear()
	claimed_versions.clear()
	invalidate_sync_cache()
	_sync_in_flight_by_relay.clear()
	_increment_queue_by_relay.clear()
	_increment_flush_scheduled_by_relay.clear()
	_increment_flush_in_flight_by_relay.clear()
	_increment_last_flush_result_by_relay.clear()
	_increment_retry_not_before_ms_by_relay.clear()
	is_setup = false
	
	if FileAccess.file_exists(INSTALLATION_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(INSTALLATION_SAVE_PATH))



func _remember_relay_state(relay_id: String, relay_state: Dictionary) -> Dictionary:
	if relay_state.is_empty():
		return {}
	
	var incoming := relay_state.duplicate(true)
	
	if _latest_relay_state_by_relay.has(relay_id):
		var known: Dictionary = _latest_relay_state_by_relay[relay_id]
		var incoming_value := int(incoming.get("value", 0))
		var known_value := int(known.get("value", 0))
		var incoming_completion := int(incoming.get("completion_version", 0))
		var known_completion := int(known.get("completion_version", 0))
		
		# Relay counters are monotonic during normal gameplay. If an older in-flight
		# sync returns after a newer increment response, keep the newer state.
		if incoming_value < known_value or incoming_completion < known_completion:
			return known.duplicate(true)
	
	_latest_relay_state_by_relay[relay_id] = incoming.duplicate(true)
	return incoming


func _remember_relay_state_in_result(relay_id: String, result: Dictionary) -> Dictionary:
	if not result.get("ok", false):
		return result
	
	var data: Variant = result.get("data", {})
	if not (data is Dictionary):
		return result
	
	var normalized := result.duplicate(true)
	var normalized_data: Dictionary = normalized.get("data", {})
	
	if normalized_data.has("relay") and normalized_data["relay"] is Dictionary:
		normalized_data["relay"] = _remember_relay_state(relay_id, normalized_data["relay"])
		normalized["data"] = normalized_data
		return normalized
	
	if normalized_data.has("state") and normalized_data["state"] is Dictionary:
		normalized_data["state"] = _remember_relay_state(relay_id, normalized_data["state"])
		normalized["data"] = normalized_data
		return normalized
	
	if normalized_data.has("value") or normalized_data.has("target") or normalized_data.has("completion_version"):
		normalized["data"] = _remember_relay_state(relay_id, normalized_data)
	
	return normalized


## Clears cached sync responses. Call this after operations that change relay state,
## such as incrementing or acknowledging a claim.
func invalidate_sync_cache(relay_id: String = "") -> void:
	if relay_id.is_empty():
		_sync_cache_by_relay.clear()
		_sync_cache_time_by_relay.clear()
		return
	
	_sync_cache_by_relay.erase(relay_id)
	_sync_cache_time_by_relay.erase(relay_id)


func _get_cached_sync_result(relay_id: String) -> Dictionary:
	if not _sync_cache_by_relay.has(relay_id):
		return {}
	
	var cached_at := int(_sync_cache_time_by_relay.get(relay_id, 0))
	var age := Time.get_ticks_msec() - cached_at
	
	if age < 0 or age >= SYNC_CACHE_MS:
		return {}
	
	var cached: Dictionary = _sync_cache_by_relay[relay_id].duplicate(true)
	cached["cached"] = true
	cached["cache_age_ms"] = age
	cached["cache_ttl_ms"] = SYNC_CACHE_MS
	return cached


func _store_sync_cache(relay_id: String, result: Dictionary) -> void:
	if not result.get("ok", false):
		return
	
	var normalized := _remember_relay_state_in_result(relay_id, result)
	_sync_cache_by_relay[relay_id] = normalized.duplicate(true)
	_sync_cache_time_by_relay[relay_id] = Time.get_ticks_msec()


func _emit_sync_completed_from_cached_result(relay_id: String, cached_result: Dictionary) -> void:
	var data: Variant = cached_result.get("data", {})
	if not (data is Dictionary):
		return
	
	var data_dict: Dictionary = data
	var relay_state: Dictionary = {}
	var claim: Dictionary = {
		"available": false,
		"completion_count": 0,
		"from_version": 0,
		"to_version": 0,
		"new_state_token": "",
		"from_cache": true
	}
	
	if data_dict.has("relay"):
		relay_state = data_dict.get("relay", {})
		claim = data_dict.get("claim", claim)
	else:
		# get_relay-shaped cached result fallback.
		relay_state = data_dict
	
	if relay_state.is_empty():
		return
	
	# Do not re-emit reward_available from cache. The reward manager already saw
	# the real HTTP result; cache hits should only refresh the UI counter path.
	relay_state = _remember_relay_state(relay_id, relay_state)
	sync_completed.emit(relay_id, relay_state, claim)

# -------------------------------------------------------------------
# INTERNAL SYNC
# -------------------------------------------------------------------

## Performs the token-changing sync request.
## This may advance state_token and may create a pending reward.
func _sync_relay_with_id(relay_id: String, idempotency_key: String) -> Dictionary:
	var headers := _game_and_installation_headers()
	headers.append("Content-Type: application/json")
	headers.append("Idempotency-Key: " + idempotency_key)
	
	var payload := {
		"state_token": state_token
	}
	
	return await _send_json_request(
		_url("/v1/relays/" + relay_id.uri_encode() + "/sync"),
		HTTPClient.METHOD_POST,
		headers,
		payload
	)


## Reads the latest public relay state while preserving an existing pending reward.
## This keeps UI values fresh without consuming/overwriting the pending claim receipt.
func _sync_relay_read_latest_with_pending_reward(relay_id: String) -> Dictionary:
	var relay_result := await get_relay(relay_id)
	
	if not relay_result.get("ok", false):
		return relay_result
	
	# Reward not available as pending
	if not pending_claims.has(relay_id):
		return { "ok": false, "reason" : "Reward not available as pending." }
	
	var relay_state: Dictionary = relay_result["data"]
	
	var pending: Dictionary = pending_claims[relay_id]
	var pending_response: Dictionary = pending.get("response", {})
	var pending_claim: Dictionary = pending_response.get("claim", {})
	
	# Merge latest relay state with the original pending reward receipt.
	# Do not overwrite claim.from_version/to_version/completion_count, because
	# that is the approved reward receipt that still needs ack.
	var response_data := {
		"relay": relay_state,
		"claim": pending_claim,
		"pending_claim": true,
		"blocked_token_write": true
	}
	
	relay_state = _remember_relay_state(relay_id, relay_state)
	sync_completed.emit(relay_id, relay_state, pending_claim)
	_emit_reward_available(relay_id, pending_claim, true)
	
	return {
		"ok": true,
		"status": 200,
		"data": response_data,
		"from_pending": true
	}


## Reads a relay without attempting a claim because another relay has a pending reward.
## This avoids token-order conflicts while still allowing the game world/UI to display fresh counters.
func _sync_relay_read_only_blocked_by_other_pending(relay_id: String) -> Dictionary:
	var relay_result := await get_relay(relay_id)
	
	if not relay_result.get("ok", false):
		return relay_result
	
	var relay_state: Dictionary = relay_result["data"]
	var blocking_ids := pending_claims.keys()
	
	var claim := {
		"available": false,
		"completion_count": 0,
		"from_version": 0,
		"to_version": int(relay_state.get("completion_version", 0)),
		"new_state_token": "",
		"blocked_by_pending_claim": true,
		"blocking_relay_ids": blocking_ids
	}
	
	var response_data := {
		"relay": relay_state,
		"claim": claim,
		"read_only": true,
		"blocked_by_pending_claim": true,
		"blocking_relay_ids": blocking_ids
	}
	
	relay_state = _remember_relay_state(relay_id, relay_state)
	sync_completed.emit(relay_id, relay_state, claim)
	
	return {
		"ok": true,
		"status": 200,
		"data": response_data,
		"read_only": true,
		"blocked_by_pending_claim": true
	}




## Updates the local claimed_versions mirror from a claim receipt.
## The value never moves backwards.
func _update_claimed_version_from_claim(relay_id: String, claim: Dictionary) -> void:
	var claimed_to := int(claim.get("to_version", claim.get("claimed_to_version", 0)))
	
	if claimed_to <= 0:
		return
	
	var previous := int(claimed_versions.get(relay_id, 0))
	
	# Never move backwards locally.
	if claimed_to < previous:
		return
	
	claimed_versions[relay_id] = claimed_to
	
	if claimed_to != previous:
		claimed_version_updated.emit(relay_id, claimed_to)


## Bulk-updates claimed_versions from server baseline_claims.
## Used after first installation registration.
## "Baseline" in the plugin's terminology means the default
## of something. A baseline claim is the event's completion counter
## the player starts at, when they first play.
func _update_claimed_versions_from_dictionary(values: Dictionary) -> void:
	for key in values.keys():
		var relay_id := str(key)
		var version := int(values[key])
		var previous := int(claimed_versions.get(relay_id, 0))
		
		if version >= previous:
			claimed_versions[relay_id] = version
			
			if version != previous:
				claimed_version_updated.emit(relay_id, version)


# -------------------------------------------------------------------
# HTTP
# -------------------------------------------------------------------

## Sends an HTTP request and normalizes the response into a Dictionary.
## Successful responses return { ok=true, status, data }.
## Failed responses return { ok=false, status, code, error, data }.
func _send_json_request(
	url: String,
	method: HTTPClient.Method,
	headers: PackedStringArray = PackedStringArray(),
	payload: Variant = null
) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	
	var request_body := ""
	
	# Only encode a body for requests that actually send JSON payloads.
	if payload != null:
		request_body = JSON.stringify(payload)
	
	# Start the request. Godot reports connection/setup errors immediately here.
	var start_error := http.request(
		url,
		headers,
		method,
		request_body
	)
	
	if start_error != OK:
		http.queue_free()
		
		return {
			"ok": false,
			"status": 0,
			"code": "request_start_failed",
			"error": "The request could not be started.",
			"godot_error": start_error
		}
	
	# Wait until the request finishes and unpack the HTTP response.
	var response: Array = await http.request_completed
	
	var result_code: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]
	
	http.queue_free()
	
	var response_text := body.get_string_from_utf8()
	var parsed_body: Variant = {}
	
	# Parse JSON responses, but keep raw text if the server returned invalid JSON.
	if not response_text.is_empty():
		parsed_body = JSON.parse_string(response_text)
		
		if parsed_body == null:
			parsed_body = {
				"raw_response": response_text
			}
	
	var succeeded := (
		result_code == HTTPRequest.RESULT_SUCCESS
		and response_code >= 200
		and response_code < 300
	)
	
	# Normalize all successful responses to the same result shape.
	if succeeded:
		return {
			"ok": true,
			"status": response_code,
			"data": parsed_body
		}
	
	var error_message := "Request failed"
	var error_code := "request_failed"
	
	if parsed_body is Dictionary:
		error_message = str(parsed_body.get("error", error_message))
		error_code = str(parsed_body.get("code", error_code))
	
	# Auth/subscription failures are important enough to broadcast separately.
	if response_code in [401, 402, 403]:
		game_access_rejected.emit(error_code, error_message)
	
	return {
		"ok": false,
		"status": response_code,
		"code": error_code,
		"error": error_message,
		"data": parsed_body,
		"godot_result": result_code
	}


# -------------------------------------------------------------------
# HEADERS / HELPERS FOR HTTP REQUESTS
# -------------------------------------------------------------------

## Helper function that joins BASE_URL and an endpoint path, also
## ensuring duplicate slashes are avoided.
func _url(path: String) -> String:
	var base := BASE_URL
	
	while base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	
	if not path.begins_with("/"):
		path = "/" + path
	
	return base + path


## Builds HTTP request headers that authenticate this game
## build for API access permissions.
func _game_headers() -> PackedStringArray:
	return PackedStringArray([
		"Authorization: Bearer " + GAME_KEY,
		"X-Game-Id: " + GAME_ID
	])


## Builds HTTP request headers that authenticate both the
## game and this local installation for API access permissions,
## and reward claim status/validation.
func _game_and_installation_headers() -> PackedStringArray:
	return PackedStringArray([
		"Authorization: Bearer " + GAME_KEY,
		"X-Game-Id: " + GAME_ID,
		"X-Installation-Id: " + installation_id,
		"X-Installation-Token: " + installation_token
	])


## Generates a random idempotency key for POST requests.
func _generate_request_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


# -------------------------------------------------------------------
# LOCAL SAVE
# -------------------------------------------------------------------

## Loads the local installation file.
func _load_installation_file() -> void:
	# First launch has no local installation file yet.
	if not FileAccess.file_exists(INSTALLATION_SAVE_PATH):
		return
	
	var file := FileAccess.open(INSTALLATION_SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	
	# Parse the local JSON file. Invalid files are ignored.
	var text := file.get_as_text()
	var parsed: Variant = JSON.parse_string(text)
	
	if not (parsed is Dictionary):
		return
	
	installation_id = str(parsed.get("installation_id", ""))
	installation_token = str(parsed.get("installation_token", ""))
	state_token = str(parsed.get("state_token", ""))
	
	var loaded_pending: Variant = parsed.get("pending_claims", {})
	
	if loaded_pending is Dictionary:
		pending_claims = loaded_pending
	else:
		pending_claims = {}
	
	var loaded_claimed_versions: Variant = parsed.get("claimed_versions", {})
	
	if loaded_claimed_versions is Dictionary:
		claimed_versions = loaded_claimed_versions
	else:
		claimed_versions = {}


## Stores an installation file locally.
func _save_installation_file() -> void:
	var file := FileAccess.open(INSTALLATION_SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Could not save Lynx Relay installation file.")
		return
	
	# Save all local SDK state needed to continue the same installation later.
	var data := {
		"installation_id": installation_id,
		"installation_token": installation_token,
		"state_token": state_token,
		"pending_claims": pending_claims,
		"claimed_versions": claimed_versions
	}
	
	file.store_string(JSON.stringify(data, "\t"))


# -------------------------------------------------------------------
# MISC, OTHER HELPERS
# -------------------------------------------------------------------

## Wrapper to emit reward_available.
func _emit_reward_available(relay_id: String, claim: Dictionary, from_pending: bool) -> void:
	var count := int(claim.get("completion_count", 0))
	if count <= 0:
		return
	
	reward_available.emit(
		relay_id,
		count,
		int(claim.get("from_version", 0)),
		int(claim.get("to_version", 0)),
		from_pending
	)
