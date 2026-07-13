class_name LynxHandler extends Node


@export var listened_event: String = "devtest"


var _claim_interaction_counter: int = 0
var _latest_claim_interaction_id: int = 0

var _last_reward_popup_version: int = -1


func _ready() -> void:
	_prime_existing_reward_popup_versions()
	
	# Signal connections for relevant callbacks
	if not LynxRelay.sync_completed.is_connected(_on_sync_completed):
		LynxRelay.sync_completed.connect(_on_sync_completed)
	
	if not LynxRelay.increment_started.is_connected(_on_local_increment_started):
		LynxRelay.increment_started.connect(_on_local_increment_started)
	
	if not LynxRelay.increment_completed.is_connected(_on_local_increment_completed):
		LynxRelay.increment_completed.connect(_on_local_increment_completed)
	
	if not LynxRewards.offer_available.is_connected(_on_offer_available):
		LynxRewards.offer_available.connect(_on_offer_available)
	
	if not LynxRewards.offer_updated.is_connected(_on_offer_available):
		LynxRewards.offer_updated.connect(_on_offer_available)
	
	# The reward manager is an autoload, so it may have loaded saved offers
	# before this scene handler connected to its signals. Re-check on the next
	# idle frame so rewards/chests reappear after restarting the game.
	call_deferred("_display_existing_offer_after_ready")


## Use this function to update your display of the goal.
func update_goal_state_visuals(relay_state: Dictionary) -> void:
	pass


## Called when this local player successfully contributed to the relay counter.
func on_player_counter_contribution(amount: int, relay_state: Dictionary) -> void:
	LynxEventPopup.show_counter_contribution(listened_event, amount, relay_state)


## Called when a reward becomes available.
func on_reward_available(offer: Dictionary) -> void:
	LynxEventPopup.show_reward_available(listened_event, offer)


## In a real game, this is where you would spawn or update a chest.
## Ideally, this is called both when a reward becomes available, and in the
## case of a higher level reward becoming available too, even if a lower level
## reward is already available to be claimed.
func display_reward_item(offer: Dictionary) -> void:
	pass


func _display_existing_offer_after_ready() -> void:
	if not LynxRewards.has_offer(listened_event):
		return
	
	var offer = LynxRewards.get_offer(listened_event)
	
	# A real active settling offer should not re-enable the object mid-claim.
	# Stale settling/prepared statuses from a previous run are normalized by
	# LynxRewardOfferManager._load_offers().
	if str(offer.get("status", "available")) == "settling":
		return
	
	# Existing saved offers are restored visually after restart, but they should
	# not show a fresh popup every time the game opens.
	display_reward_item(offer)


## Called immediately when the player attempts claiming their reward.
func on_player_reward_claim_start() -> void:
	pass


## Called after the player attempts claiming their reward, and Lynx validated
## the claim procedure successfully.
func on_player_reward_claim_success() -> void:
	pass


## Called after the player attempts claiming their reward, and Lynx failed
## to validate the claim procedure.
func on_player_reward_claim_fail() -> void:
	pass


func _on_local_increment_started(relay_id: String, amount: int) -> void:
	if relay_id != listened_event:
		return


func _on_local_increment_completed(
	relay_id: String,
	amount: int,
	relay_state: Dictionary,
	result: Dictionary
) -> void:
	if relay_id != listened_event:
		return
	
	if not result.get("ok", false):
		return
	
	on_player_counter_contribution(amount, relay_state)


## Automatic callback function of a 1-second timer to retrieve event information.
func _on_getter_timer_timeout() -> void:
	LynxRelay.sync_relay(listened_event)


## Called when momentary goal values have been retrieved.
func _on_sync_completed(relay_id: String, relay_state: Dictionary, claim: Dictionary) -> void:
	if relay_id != listened_event:
		return
	
	update_goal_state_visuals(relay_state)


## Called when LynxRewards creates or updates a reward offer.
func _on_offer_available(relay_id: String, offer: Dictionary) -> void:
	if relay_id != listened_event:
		return
	
	# Reward popup should no longer be suppressed by recent local increments.
	# If an increment popup is queued/playing, LynxEventPopup will interrupt it.
	if _should_show_reward_popup(relay_id, offer):
		on_reward_available(offer)
	
	# Do not re-enable/re-spawn the interaction object while an existing
	# reward claim is being settled. If the offer upgrades during settlement,
	# the running claim flow can absorb the higher version.
	if str(offer.get("status", "available")) == "settling":
		return
	
	display_reward_item(offer)


## Called when the player performed the interaction of claiming their reward.
func _on_offer_clear_interaction() -> void:
	# The interaction area can still emit after the visual reward was hidden/cleared.
	# If there is no current Lynx offer, ignore the interaction instead of
	# reporting a fake failure.
	if not LynxRewards.has_offer(listened_event):
		return
	
	_claim_interaction_counter += 1
	var interaction_id := _claim_interaction_counter
	_latest_claim_interaction_id = interaction_id
	
	# Performed immediately so that players don't see the downtime "lag"
	# of the claim verification request.
	on_player_reward_claim_start()
	
	var result: Dictionary = await LynxRewards.prepare_offer_claim(listened_event)
	
	# A newer reward interaction started while this one was awaiting.
	# Do not call success or fail for this old result.
	if _latest_claim_interaction_id != interaction_id:
		return
	
	# Superseded is not a failed reward claim. It only means a newer
	# request became authoritative while this older await was still running.
	if result.get("superseded", false):
		return
	
	if result.get("ok", false):
		## This is where you would despawn a chest the player claimed
		## and grant them the respective loot, for example.
		on_player_reward_claim_success()
		LynxRewards.complete_offer(listened_event)
		await LynxRelay.sync_relay(listened_event, true)
	else:
		# Claim failed for some reason; keep chest
		on_player_reward_claim_fail()


func _prime_existing_reward_popup_versions() -> void:
	if not LynxRewards.has_offer(listened_event):
		return
	
	var offer = LynxRewards.get_offer(listened_event)
	var version = _get_offer_to_version(offer)
	
	if version <= 0:
		return
	
	_last_reward_popup_version = version


func _should_show_reward_popup(relay_id: String, offer: Dictionary) -> bool:
	var version := _get_offer_to_version(offer)
	
	if version <= 0:
		return true
	
	var last_version := int(_last_reward_popup_version)
	
	if version <= last_version:
		return false
	
	_last_reward_popup_version = version
	return true


func _get_offer_to_version(offer: Dictionary) -> int:
	return int(offer.get(
		"to_version",
		offer.get(
			"reward_version",
			offer.get("completion_version", 0)
		)
	))
