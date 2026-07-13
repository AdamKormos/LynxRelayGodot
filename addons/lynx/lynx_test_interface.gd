class_name LynxTestInterface extends CanvasLayer


## Short test UI using LynxRewardOfferManager.
##
## Required autoloads:
## - LynxRelay
## - LynxRewards
##
## This file is intentionally small:
## - LynxRelay handles networking/tokens.
## - LynxRewards handles saved reward offers.
## - This UI only reacts to signals and grants the reward.


## Test relay id used by this UI.
const RELAY_ID := "devtest"


## True after the first successful relay sync.
## Used only to avoid repeatedly changing the initial setup button text.
var sync_done_once := false

## Prevents overlapping async button actions.
## This keeps test UI behavior predictable during sync/increment/claim calls.
var busy := false


## Initializes UI state, connects signals and starts setup diagnostics.
func _ready() -> void:
	%EventName.text = "Test event: " + RELAY_ID
	
	%IncrementButton.disabled = true
	%IncrementButton.text = "Setting up..."
	
	%ClaimReward.disabled = true
	%ClaimReward.text = "NO REWARD"
	
	_connect_signals()
	
	# Do not silently wait forever if the LynxRelay autoload failed before
	# this UI connected its signals. This does not change any event IDs; it
	# only retries/awaits setup and shows visible diagnostics.
	call_deferred("_ensure_setup_started")


## Connects LynxRelay and LynxRewards signals used by the test UI.
func _connect_signals() -> void:
	if not LynxRelay.setup_completed.is_connected(on_setup_completed):
		LynxRelay.setup_completed.connect(on_setup_completed)
	
	if not LynxRelay.sync_completed.is_connected(_on_sync_completed):
		LynxRelay.sync_completed.connect(_on_sync_completed)
	
	if not LynxRewards.offer_available.is_connected(_on_offer_available):
		LynxRewards.offer_available.connect(_on_offer_available)
	
	if not LynxRewards.offer_updated.is_connected(_on_offer_available):
		LynxRewards.offer_updated.connect(_on_offer_available)
	
	if not LynxRewards.offer_cleared.is_connected(_on_offer_cleared):
		LynxRewards.offer_cleared.connect(_on_offer_cleared)
	
	if not LynxRewards.offer_settlement_failed.is_connected(_on_offer_settlement_failed):
		LynxRewards.offer_settlement_failed.connect(_on_offer_settlement_failed)
	
	if not LynxRelay.setup_failed.is_connected(_on_setup_failed):
		LynxRelay.setup_failed.connect(_on_setup_failed)
	
	if not LynxRelay.request_failed.is_connected(_on_request_failed):
		LynxRelay.request_failed.connect(_on_request_failed)
	
	if not LynxRelay.game_access_rejected.is_connected(_on_game_access_rejected):
		LynxRelay.game_access_rejected.connect(_on_game_access_rejected)
	
	if not LynxRelay.increment_failed.is_connected(_on_increment_failed):
		LynxRelay.increment_failed.connect(_on_increment_failed)


## Starts or awaits LynxRelay setup and shows errors instead of leaving the UI at "Setting up...".
func _ensure_setup_started() -> void:
	_show_event_config_warning_if_needed()
	
	if LynxRelay.is_setup:
		await on_setup_completed()
		return
	
	var setup_ok: bool = await LynxRelay.setup()
	
	if setup_ok:
		await on_setup_completed()
	elif %IncrementButton.text == "Setting up...":
		_show_boot_error("Lynx setup failed. Check the Output panel for the API error.")


## Warns about config mismatches without rewriting any project values.
func _show_event_config_warning_if_needed() -> void:
	if not LynxRelay.TRACKED_RELAYS.has(RELAY_ID):
		push_warning(
			"Lynx test UI RELAY_ID '" + RELAY_ID + "' is not listed in LynxRelay.TRACKED_RELAYS: " + str(LynxRelay.TRACKED_RELAYS)
		)


## Displays boot/setup/request failures in the test UI.
func _show_boot_error(message: String) -> void:
	%IncrementButton.disabled = true
	%IncrementButton.text = "SETUP ERROR"
	%ClaimReward.disabled = true
	%ClaimReward.text = "NO REWARD"
	%Counter.text = message


func _format_result_error(result: Dictionary) -> String:
	var code := str(result.get("code", ""))
	var error := str(result.get("error", result.get("message", "")))
	var status := int(result.get("status", 0))
	
	var parts: Array[String] = []
	if status != 0:
		parts.append("status=" + str(status))
	if not code.is_empty():
		parts.append("code=" + code)
	if not error.is_empty():
		parts.append(error)
	
	if parts.is_empty():
		return str(result)
	
	var message := ""
	for part in parts:
		if message.is_empty():
			message = part
		else:
			message += " | " + part
	
	return message


func _on_setup_failed(message: String, code: String) -> void:
	_show_boot_error("Setup failed: " + code + " | " + message)


func _on_request_failed(action: String, relay_id: String, result: Dictionary) -> void:
	_show_boot_error("Lynx " + action + " failed for '" + relay_id + "': " + _format_result_error(result))


func _on_game_access_rejected(code: String, message: String) -> void:
	_show_boot_error("Game access rejected: " + code + " | " + message)


func _on_increment_failed(relay_id: String, amount: int, result: Dictionary) -> void:
	_show_boot_error("Increment failed for '" + relay_id + "': " + _format_result_error(result))


## Runs the first sync after LynxRelay setup is ready.
func on_setup_completed() -> void:
	if busy:
		return
	
	busy = true
	
	%IncrementButton.disabled = true
	%IncrementButton.text = "Syncing..."
	%ClaimReward.disabled = true
	
	var results: Dictionary = await LynxRelay.sync_tracked_relays()
	
	if results.is_empty():
		_show_boot_error("No tracked Lynx relays are configured.")
		busy = false
		return
	
	var any_ok := false
	for raw_result in results.values():
		if raw_result is Dictionary:
			var result: Dictionary = raw_result
			if result.get("ok", false):
				any_ok = true
				break
	
	if not any_ok:
		_show_boot_error("Tracked relay sync failed: " + str(results))
		busy = false
		return
	
	_update_local_version()
	
	%IncrementButton.disabled = false
	%IncrementButton.text = "INCREMENT"
	
	busy = false
	_refresh_reward_button()


## Updates visible relay values after LynxRelay completes a sync.
## The actual reward offer creation is handled by LynxRewards, not this UI.
func _on_sync_completed(relay_id: String, relay_state: Dictionary, claim: Dictionary) -> void:
	if relay_id != RELAY_ID:
		return
	
	var value = int(relay_state.get("value", 0))
	var target = LynxRelay.get_goal_target_from_state(relay_state)
	var server_version = int(relay_state.get("completion_version", 0))
	
	%Counter.text = "Count: " + str(value) + "/" + str(target)
	%ServerVersion.text = "Server version: " + str(server_version)
	_update_local_version()
	
	if not sync_done_once:
		sync_done_once = true
		%IncrementButton.disabled = false
		%IncrementButton.text = "INCREMENT"
	
	_refresh_reward_button()


## Called when LynxRewards creates or updates a reward offer.
## In a real game, this is where you would spawn or update a chest.
func _on_offer_available(relay_id: String, offer: Dictionary) -> void:
	if relay_id != RELAY_ID:
		return
	
	# In a real game this is where you would spawn or update the chest.
	# Example:
	# spawn_or_update_lynx_chest(relay_id, offer)
	print("Lynx offer available: ", offer)
	
	_refresh_reward_button()


## Called when LynxRewards clears a reward offer.
## In a real game, this is where you would despawn the chest.
func _on_offer_cleared(relay_id: String) -> void:
	if relay_id != RELAY_ID:
		return
	
	# In a real game this is where you would despawn the chest.
	# Example:
	# despawn_lynx_chest(relay_id)
	_refresh_reward_button()


## Called when LynxRewards could not prepare a reward offer.
func _on_offer_settlement_failed(relay_id: String, result: Dictionary) -> void:
	if relay_id != RELAY_ID:
		return
	
	push_warning("Lynx reward settlement failed: " + str(result))
	_refresh_reward_button()


## Test action that increments the relay value.
func _on_increment_button_pressed() -> void:
	if busy:
		return
	
	busy = true
	
	%IncrementButton.disabled = true
	%IncrementButton.text = "Incrementing..."
	%ClaimReward.disabled = true
	
	await LynxRelay.increment_relay(RELAY_ID, 10)
	
	%IncrementButton.disabled = false
	%IncrementButton.text = "INCREMENT"
	
	busy = false
	_refresh_reward_button()


## Test action that claims/opens the current reward offer.
## The button should only be enabled if LynxRewards already has an offer.
func _on_claim_reward_pressed() -> void:
	if busy:
		return
	
	if not LynxRewards.has_offer(RELAY_ID):
		_refresh_reward_button()
		return
	
	busy = true
	
	%ClaimReward.disabled = true
	%ClaimReward.text = "Claiming..."
	%IncrementButton.disabled = true
	
	var result: Dictionary = await LynxRewards.prepare_offer_claim(RELAY_ID)
	
	# Superseded is not a real failure. It means a newer claim request became
	# authoritative while this older await was still running.
	if result.get("superseded", false):
		%IncrementButton.disabled = false
		busy = false
		_refresh_reward_button()
		return
	
	if not result.get("ok", false):
		push_warning("Could not prepare Lynx reward: " + str(result))
		%IncrementButton.disabled = false
		busy = false
		_refresh_reward_button()
		return
	
	var offer: Dictionary = result["offer"]
	
	# Real game order:
	# 1. Give/open the chest.
	# 2. Save the game.
	# 3. Complete the local Lynx offer.
	_give_highest_reward_chest(offer)
	
	# save_game()
	
	LynxRewards.complete_offer(RELAY_ID)
	
	await LynxRelay.sync_relay(RELAY_ID, true)
	
	_update_local_version()
	
	%IncrementButton.disabled = false
	busy = false
	_refresh_reward_button()


## Placeholder reward grant.
## Replace this with your own chest, item, currency or inventory logic.
func _give_highest_reward_chest(offer: Dictionary) -> void:
	var reward_version := int(offer.get("reward_version", offer.get("to_version", 0)))
	var completion_count := int(offer.get("completion_count", 0))
	var from_version := int(offer.get("from_version", 0))
	var to_version := int(offer.get("to_version", reward_version))
	
	print(
		"Giving highest Lynx reward chest: reward_version=",
		reward_version,
		" absorbed_versions=",
		from_version + 1,
		"-",
		to_version,
		" count=",
		completion_count
	)
	
	# Example:
	# player_coins += _coins_for_reward_version(reward_version)
	# or:
	# open_chest_scene(reward_version)


## Updates the reward button from LynxRewards' current offer state.
func _refresh_reward_button() -> void:
	if busy:
		%ClaimReward.disabled = true
		return
	
	if not LynxRewards.has_offer(RELAY_ID):
		%ClaimReward.disabled = true
		%ClaimReward.text = "NO REWARD"
		return
	
	var offer = LynxRewards.get_offer(RELAY_ID)
	var reward_version = int(offer.get("reward_version", offer.get("to_version", 0)))
	var completion_count = int(offer.get("completion_count", 0))
	
	%ClaimReward.disabled = false
	%ClaimReward.text = "CLAIM HIGHEST #" + str(reward_version) + " (x" + str(completion_count) + ")"


## Updates the local claimed version label.
func _update_local_version() -> void:
	%LocalVersion.text = "Local version: " + str(LynxRelay.get_client_claimed_version(RELAY_ID))
