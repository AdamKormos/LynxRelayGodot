class_name LynxHandlerCoin2D extends LynxHandler


@export var counter_label : Label
@export var coin_get_area : CoinGetArea2D
@export var player : Player2D


func _ready() -> void:
	super()
	# Hide coin by default.
	coin_get_area.visible = false
	# When interacting with the coin, it is not claimed instantly. Instead,
	# Lynx has to validate and log the reward claim process.
	coin_get_area.coin_claim_ready.connect(_on_offer_clear_interaction)


## Use this function to update your display of the goal.
func update_goal_state_visuals(relay_state: Dictionary):
	var value = int(relay_state.get("value", 0))
	var target = LynxRelay.get_goal_target_from_state(relay_state)
	counter_label.text = str(value) + "/" + str(target)


## In a real game, this is where you would spawn or update a chest.
## Ideally, this is called both when a reward becomes available, and in the
## case of a higher level reward becoming available too (even if a lower level
## reward is already available to be claimed), so you should make sure
## only the higher level reward can be claimed. This usually means destroying
## the lower level reward, or altering the object's information.
func display_reward_item(offer: Dictionary):
	coin_get_area.visible = true


## Called immediately when the player attempts claimming their reward.
func on_player_reward_claim_start():
	coin_get_area.visible = false


## Called after the player attempts claimming their reward, and Lynx validated
## the claim procedure successfully.
func on_player_reward_claim_success():
	coin_get_area.visible = false
	player.coin_count += 1


## Called after the player attempts claimming their reward, and Lynx failed
## to validate the claim procedure.
func on_player_reward_claim_fail():
	coin_get_area.visible = true
