class_name LynxRewardOfferManager extends Node


## Generic game-layer reward offer helper for LynxRelay.
##
## Recommended Autoload name:
##   LynxRewards
##
## Recommended Autoload order:
##   1. LynxRelay
##   2. LynxRewards
##
## Purpose:
## - LynxRelay handles server sync, pending claims and token safety.
## - This helper turns claimable Lynx versions into simple game-facing offers.
##
## MVP policy implemented here:
## - One offer/chest per relay.
## - If multiple reward versions are claimable, the offer targets the highest one.
## - The highest reward is assumed to include/replace the lower rewards.
##
## Example:
##   local claimed version = 46
##   server completion_version = 49
##
## This helper creates:
##   reward_version = 49
##   completion_count = 3
##
## The game can show one chest:
##   "Community Reward #49"
##
## The game should call:
##   var result := await LynxRewards.prepare_offer_claim("devtest")
##   if result["ok"]:
##       give_reward(result["offer"])
##       save_game()
##       LynxRewards.complete_offer("devtest")


## Emitted when a new local reward offer is created for a relay.
signal offer_available(relay_id: String, offer: Dictionary)

## Emitted when an existing local reward offer is upgraded to a newer reward version.
signal offer_updated(relay_id: String, offer: Dictionary)

## Emitted when a local reward offer is cleared after the game completes it.
signal offer_cleared(relay_id: String)

## Emitted when an offer has been safely settled and is ready for the game to grant.
signal offer_prepared(relay_id: String, offer: Dictionary)

## Emitted when sync/ack settlement failed while preparing an offer.
signal offer_settlement_failed(relay_id: String, result: Dictionary)


## Local save path for game-facing reward offers.
## These are local entitlements, not server state.
const SAVE_PATH := "user://lynx_reward_offers.json"


## Empty means: accept all relays reported by LynxRelay.
## Otherwise, only relays listed here can create reward offers.
var tracked_relays: Array[String] = []

## Saved reward offers by relay id.
var offers: Dictionary = {}

## Latest public relay states received from LynxRelay.sync_completed.
var latest_relay_states: Dictionary = {}

## Safety limit for chained sync/ack settlement.
var settlement_safety_limit := 20

## Monotonic id used to identify the newest async claim/preparation flow.
## If a newer claim starts while an older await is still running, the older
## result is treated as superseded, not as a real failure.
var _claim_request_counter: int = 0
var _active_claim_request_ids: Dictionary = {}


## Loads saved offers and connects to LynxRelay signals.
func _ready() -> void:
	# Restore saved local reward offers before listening for new updates.
	_load_offers()
	
	# Use LynxRelay's central relay list by default, so scenes do not need
	# to configure LynxRewards manually.
	configure(LynxRelay.TRACKED_RELAYS)
	
	# Listen for normal relay sync updates.
	if not LynxRelay.sync_completed.is_connected(_on_lynx_sync_completed):
		LynxRelay.sync_completed.connect(_on_lynx_sync_completed)
	
	# Listen for explicit reward availability events emitted by LynxRelay.
	if not LynxRelay.reward_available.is_connected(_on_lynx_reward_available):
		LynxRelay.reward_available.connect(_on_lynx_reward_available)
	
	# Re-emit saved offers after LynxRelay setup completes.
	if not LynxRelay.setup_completed.is_connected(_on_lynx_setup_completed):
		LynxRelay.setup_completed.connect(_on_lynx_setup_completed)
	
	# Also emit once on the next idle frame. This is important when the game
	# is restarted with a saved local offer, because scene-level handlers usually
	# connect to LynxRewards after this autoload's _ready() has already run.
	call_deferred("_emit_saved_offers")


## Configures which relays this manager should listen to.
## Usually called automatically from _ready() with LynxRelay.TRACKED_RELAYS.
## Pass an empty array to accept all relay ids.
func configure(relay_ids: Array = []) -> void:
	tracked_relays.clear()
	
	for relay_id in relay_ids:
		tracked_relays.append(str(relay_id))
	
	_emit_saved_offers()


## Returns true when this relay currently has a local reward offer.
## Returns true when this relay currently has a local reward offer.
func has_offer(relay_id: String) -> bool:
	return offers.has(relay_id)


## Returns the saved reward offer for this relay.
## Returns a copy of the saved reward offer for this relay.
## Returns an empty Dictionary if there is no offer.
func get_offer(relay_id: String) -> Dictionary:
	return offers.get(relay_id, {}).duplicate(true)


## Returns all currently saved offers.
## Returns a copy of all currently saved offers.
func get_all_offers() -> Dictionary:
	return offers.duplicate(true)


## Manually clears an offer.
## Mostly useful for debug tools.
## Manually clears an offer.
## Mostly useful for debug tools or manual recovery screens.
func clear_offer(relay_id: String) -> void:
	if not offers.has(relay_id):
		return
	
	offers.erase(relay_id)
	_save_offers()
	offer_cleared.emit(relay_id)


## Converts a Lynx sync response into a game-facing reward offer if needed.
## You normally do not need to call this manually because the manager is
## already connected to LynxRelay.sync_completed.
## Converts a Lynx sync response into a game-facing reward offer if needed.
## This is the main dynamic bridge between LynxRelay and the game reward UI.
func update_from_sync(relay_id: String, relay_state: Dictionary, claim: Dictionary) -> void:
	if not _is_tracked(relay_id):
		return
	
	latest_relay_states[relay_id] = relay_state.duplicate(true)
	
	var local_version = LynxRelay.get_client_claimed_version(relay_id)
	var server_version := int(relay_state.get("completion_version", 0))
	
	var claim_count := int(claim.get("completion_count", 0))
	var claim_to := int(claim.get("to_version", 0))
	
	var highest_known_version := int(max(server_version, claim_to))
	
	# No new server progress and no claimable receipt.
	# Existing local offers remain available.
	if highest_known_version <= local_version and claim_count <= 0:
		return
	
	if highest_known_version <= local_version:
		return
	
	_create_or_upgrade_offer(relay_id, highest_known_version)


## Prepares the current offer for claiming.
##
## This advances Lynx's local claimed version until it covers the offer's
## target version. It does NOT grant the reward and does NOT clear the offer.
##
## Correct usage:
##   var result := await LynxRewards.prepare_offer_claim(relay_id)
##   if result["ok"]:
##       var offer: Dictionary = result["offer"]
##       give_reward(offer)
##       save_game()
##       LynxRewards.complete_offer(relay_id)
##
## This split is intentional:
## - The manager can safely settle Lynx tokens.
## - The game remains responsible for granting/saving its own reward.
## Prepares the current offer for claiming.
## This settles LynxRelay tokens but does not grant or clear the game reward.
func prepare_offer_claim(relay_id: String) -> Dictionary:
	var request_id := _begin_claim_request(relay_id)
	
	if not offers.has(relay_id):
		return {
			"ok": false,
			"code": "no_offer",
			"error": "No reward offer exists for this relay."
		}
	
	var offer: Dictionary = offers[relay_id]
	offer["status"] = "settling"
	offer["updated_at_unix"] = Time.get_unix_time_from_system()
	offers[relay_id] = offer
	_save_offers()
	
	var settled_result: Dictionary = await _settle_relay_to_offer(relay_id, request_id)
	
	# A newer claim/interaction started while this request was awaiting.
	# This is not a real claim failure; the caller should simply ignore it.
	if _is_claim_request_superseded(relay_id, request_id):
		return _make_superseded_result(relay_id, request_id)
	
	if settled_result.get("superseded", false):
		return settled_result
	
	if not settled_result.get("ok", false):
		var failed_offer: Dictionary = offers.get(relay_id, offer)
		failed_offer["status"] = "available"
		failed_offer["updated_at_unix"] = Time.get_unix_time_from_system()
		offers[relay_id] = failed_offer
		_save_offers()
		
		var fail_result := {
			"ok": false,
			"code": str(settled_result.get("code", "settlement_failed")),
			"error": str(settled_result.get("error", "Could not settle Lynx tokens to the reward offer target.")),
			"offer": failed_offer.duplicate(true),
			"details": settled_result
		}
		
		offer_settlement_failed.emit(relay_id, fail_result)
		return fail_result
	
	offer = offers.get(relay_id, offer)
	offer["status"] = "prepared"
	offer["updated_at_unix"] = Time.get_unix_time_from_system()
	offers[relay_id] = offer
	_save_offers()
	
	offer_prepared.emit(relay_id, offer.duplicate(true))
	
	return {
		"ok": true,
		"offer": offer.duplicate(true)
	}


func attempt_offer_claim_interaction_result(relay_id: String) -> Dictionary:
	var result: Dictionary = await prepare_offer_claim(relay_id)
	
	# Superseded means a newer interaction became authoritative.
	# Do not warn, do not treat it as a failed reward claim.
	if result.get("superseded", false):
		return result
	
	if not result.get("ok", false):
		push_warning("Could not prepare Lynx reward: " + str(result))
		return result
	
	var offer: Dictionary = result.get("offer", {})
	
	# Real game order in a production game should be:
	# 1. Give/open the chest.
	# 2. Save the game.
	# 3. Complete the local Lynx offer.
	#
	# This convenience interaction helper keeps the old sample behavior:
	# it validates/prepares the offer, clears the local offer, then lets the
	# handler call its success callback.
	complete_offer(relay_id)
	await LynxRelay.sync_relay(relay_id, true)
	
	return {
		"ok": true,
		"offer": offer.duplicate(true)
	}


func attempt_offer_claim_interaction(relay_id : String) -> bool:
	var result: Dictionary = await attempt_offer_claim_interaction_result(relay_id)
	
	if result.get("superseded", false):
		return false
	
	return result.get("ok", false)


## Completes and removes a prepared/available offer after the game has granted
## and saved the reward.
##
## Call this only after your own game reward is safely stored.
## Completes and removes an offer after the game has granted and saved the reward.
func complete_offer(relay_id: String) -> bool:
	if not offers.has(relay_id):
		return false
	
	offers.erase(relay_id)
	_save_offers()
	offer_cleared.emit(relay_id)
	return true


## Optional convenience wrapper.
## Calls LynxRelay.sync_relay(); the manager will receive sync_completed and
## update offers automatically.
## Optional convenience wrapper around LynxRelay.sync_relay().
func sync_relay(relay_id: String) -> Dictionary:
	return await LynxRelay.sync_relay(relay_id)


## Optional convenience wrapper.
## Optional convenience wrapper around LynxRelay.sync_tracked_relays().
func sync_tracked_relays() -> void:
	await LynxRelay.sync_tracked_relays()


# -------------------------------------------------------------------
# LynxRelay signal hooks
# -------------------------------------------------------------------

## Re-emits saved offers after LynxRelay setup completes.
func _on_lynx_setup_completed() -> void:
	_emit_saved_offers()


## Handles relay sync output and turns it into reward offers.
func _on_lynx_sync_completed(relay_id: String, relay_state: Dictionary, claim: Dictionary) -> void:
	update_from_sync(relay_id, relay_state, claim)


## Handles LynxRelay's explicit reward_available signal.
## This is a secondary path; update_from_sync() is the main dynamic bridge.
func _on_lynx_reward_available(
	relay_id: String,
	completion_count: int,
	from_version: int,
	to_version: int,
	from_pending: bool
) -> void:
	if not _is_tracked(relay_id):
		return
	
	if completion_count <= 0:
		return
	
	var latest_state: Dictionary = latest_relay_states.get(relay_id, {})
	var latest_server_version := int(latest_state.get("completion_version", to_version))
	var highest_known_version := int(max(to_version, latest_server_version))
	
	_create_or_upgrade_offer(relay_id, highest_known_version)


# -------------------------------------------------------------------
# Offer creation/update
# -------------------------------------------------------------------

## Creates or upgrades the single local reward offer for this relay.
func _create_or_upgrade_offer(relay_id: String, highest_version: int) -> void:
	var local_version = LynxRelay.get_client_claimed_version(relay_id)
	
	# If there is no offer and local is already caught up, do nothing.
	if not offers.has(relay_id) and highest_version <= local_version:
		return
	
	var existing: Dictionary = offers.get(relay_id, {})
	var existing_to := int(existing.get("to_version", 0))
	
	# If an offer already exists and already covers this version, keep it.
	# This prevents the same reward from being re-emitted every sync/poll.
	if existing_to >= highest_version:
		return
	
	var is_new_offer := not offers.has(relay_id)
	
	# Keep the original from_version for existing offers.
	# That way one highest-tier chest can still represent everything that
	# became available since the offer first appeared.
	var from_version := int(existing.get("from_version", local_version))
	var to_version := highest_version
	var completion_count = max(0, to_version - from_version)
	
	if completion_count <= 0:
		return
	
	var previous_status := str(existing.get("status", "available"))
	
	var offer := {
		"relay_id": relay_id,
		"from_version": from_version,
		"to_version": to_version,
		"completion_count": completion_count,
		"reward_version": to_version,
		"status": previous_status,
		"created_at_unix": existing.get("created_at_unix", Time.get_unix_time_from_system()),
		"updated_at_unix": Time.get_unix_time_from_system()
	}
	
	offers[relay_id] = offer
	_save_offers()
	
	if is_new_offer:
		offer_available.emit(relay_id, offer.duplicate(true))
	else:
		offer_updated.emit(relay_id, offer.duplicate(true))


## Advances LynxRelay local state until it reaches the saved offer target.
func _settle_relay_to_offer(relay_id: String, request_id: int) -> Dictionary:
	var safety := 0
	
	while safety < settlement_safety_limit:
		if _is_claim_request_superseded(relay_id, request_id):
			return _make_superseded_result(relay_id, request_id)
		
		safety += 1
		
		if not offers.has(relay_id):
			return { "ok": true }
		
		var offer: Dictionary = offers[relay_id]
		var target_version := int(offer.get("to_version", 0))
		var local_version = LynxRelay.get_client_claimed_version(relay_id)
		
		if local_version >= target_version:
			return { "ok": true }
		
		if not LynxRelay.has_pending_claim(relay_id):
			var sync_result: Dictionary = await LynxRelay.sync_relay(relay_id, true)
			
			if _is_claim_request_superseded(relay_id, request_id):
				return _make_superseded_result(relay_id, request_id)
			
			if not sync_result.get("ok", false):
				push_warning("Lynx sync failed while preparing reward offer: " + str(sync_result))
				return {
					"ok": false,
					"code": "sync_failed",
					"error": "Lynx sync failed while preparing reward offer.",
					"details": sync_result
				}
		
		if _is_claim_request_superseded(relay_id, request_id):
			return _make_superseded_result(relay_id, request_id)
		
		if not LynxRelay.has_pending_claim(relay_id):
			return {
				"ok": LynxRelay.get_client_claimed_version(relay_id) >= target_version,
				"code": "no_pending_claim",
				"error": "No pending claim was available after sync."
			}
		
		var pending: Dictionary = LynxRelay.get_pending_claim(relay_id)
		var response: Dictionary = pending.get("response", {})
		var claim: Dictionary = response.get("claim", {})
		var claim_to := int(claim.get("to_version", 0))
		
		# If the receipt reaches beyond the current offer, upgrade the local
		# offer before acking. This prevents token advancement without a saved
		# local reward entitlement.
		if claim_to > target_version:
			_create_or_upgrade_offer(relay_id, claim_to)
		
		if _is_claim_request_superseded(relay_id, request_id):
			return _make_superseded_result(relay_id, request_id)
		
		var acked = LynxRelay.ack_claim(relay_id)
		
		if not acked:
			if _is_claim_request_superseded(relay_id, request_id):
				return _make_superseded_result(relay_id, request_id)
			
			push_warning("Lynx ack_claim failed while preparing reward offer.")
			return {
				"ok": false,
				"code": "ack_failed",
				"error": "Lynx ack_claim failed while preparing reward offer."
			}
	
	push_warning("Reward offer settlement stopped by safety limit.")
	return {
		"ok": false,
		"code": "settlement_safety_limit",
		"error": "Reward offer settlement stopped by safety limit."
	}


# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

## Returns true if this relay id is accepted by the manager.
func _is_tracked(relay_id: String) -> bool:
	return tracked_relays.is_empty() or tracked_relays.has(relay_id)


func _begin_claim_request(relay_id: String) -> int:
	_claim_request_counter += 1
	_active_claim_request_ids[relay_id] = _claim_request_counter
	return _claim_request_counter


func _is_claim_request_superseded(relay_id: String, request_id: int) -> bool:
	return int(_active_claim_request_ids.get(relay_id, -1)) != request_id


func _make_superseded_result(relay_id: String, request_id: int) -> Dictionary:
	return {
		"ok": false,
		"superseded": true,
		"code": "superseded",
		"error": "A newer Lynx reward claim request started for this relay.",
		"request_id": request_id,
		"offer": get_offer(relay_id)
	}


## Emits saved offers to the game so chests can respawn after restart.
func _emit_saved_offers() -> void:
	for relay_id in offers.keys():
		if not _is_tracked(str(relay_id)):
			continue
		
		var offer: Dictionary = offers[relay_id]
		
		if str(offer.get("status", "available")) == "prepared":
			offer_prepared.emit(str(relay_id), offer.duplicate(true))
		else:
			offer_available.emit(str(relay_id), offer.duplicate(true))


## Loads saved reward offers from user://.
func _load_offers() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	
	if file == null:
		return
	
	var text := file.get_as_text()
	var parsed: Variant = JSON.parse_string(text)
	
	if parsed is Dictionary:
		offers = parsed
	else:
		offers = {}
	
	# Runtime-only states must not make a reward disappear after restarting
	# the game. If the app closed while a claim was settling/prepared, the local
	# offer is still the player's local entitlement, so show it again.
	var normalized := false
	
	for relay_id in offers.keys():
		var offer: Dictionary = offers[relay_id]
		var status := str(offer.get("status", "available"))
		
		if status == "settling" or status == "prepared":
			offer["status"] = "available"
			offer["updated_at_unix"] = Time.get_unix_time_from_system()
			offers[relay_id] = offer
			normalized = true
	
	if normalized:
		_save_offers()


## Saves reward offers to user://.
func _save_offers() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	
	if file == null:
		push_warning("Could not save Lynx reward offers.")
		return
	
	file.store_string(JSON.stringify(offers, "\t"))
