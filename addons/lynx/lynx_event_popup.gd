extends CanvasLayer


@export var animation_name: String = "Display"

@export var animation_player: AnimationPlayer
@export var event_icon: TextureRect
@export var event_name_label: RichTextLabel
@export var event_progress_label: RichTextLabel
@export var relay_hyperlink_label: RichTextLabel

@export var default_event_name: String = "Community Event"
@export var reward_available_text: String = "Reward available"
@export var reward_claimed_text: String = "Reward claimed"

@export var show_amount_in_counter_popup: bool = true
@export var show_percentage_when_available: bool = false

@export var relay_page_open_available_by_tap : bool = true
## If your game doesn't support clicking the popup's
## HyperlinkText, you must create an input action that
## can automatically open the displayed event's website
## while the popup is active.
@export var relay_page_open_input_action : String = ""

var _message_queue: Array[Dictionary] = []

var _is_running_queue: bool = false
var _active_message_type: String = ""
var active_displayed_relay_id: String = ""

var _queue_runner_id: int = 0
var _display_id: int = 0



func _ready() -> void:
	if relay_page_open_available_by_tap:
		relay_hyperlink_label.text = "See all games [url]HERE"
	else:
		assert(relay_page_open_input_action != "", "Lynx Error: You disabled opening an event's website by tapping, but haven't specified an input key to do so. Please create an input action and assign it to the popup.")
		var events = InputMap.action_get_events(relay_page_open_input_action)
		assert(!events.is_empty(), "Lynx Error: No input action attached to the event website opening action.")
		var action_as_text : String = OS.get_keycode_string(events[0].physical_keycode)
		relay_hyperlink_label.text = "[" + action_as_text + "] to see all games"


func _process(delta: float) -> void:
	if visible and relay_page_open_input_action != "" and Input.is_action_just_pressed(relay_page_open_input_action):
		_on_hyperlink_text_meta_clicked(null)


func show_counter_contribution(relay_id: String, amount: int, relay_state: Dictionary = {}) -> void:
	var state := _extract_relay_state(relay_state)
	var event_name := _get_event_display_name(relay_id, state)
	
	var value := int(state.get("value", 0))
	var target := int(state.get("target", 0))
	
	var progress_text := ""
	
	if target > 0:
		progress_text = str(value) + "/" + str(target)
	else:
		progress_text = str(value)
	
	if show_amount_in_counter_popup and amount > 0:
		progress_text = "+" + str(amount) + "   " + progress_text
	
	if show_percentage_when_available and target > 0:
		var percent = clamp(float(value) / float(target), 0.0, 1.0)
		progress_text += "   " + str(int(round(percent * 100.0))) + "%"
	
	_enqueue_message({
		"type": "increment",
		"event_name": event_name,
		"event_progress": progress_text,
		"relay_id" : relay_id
	})


func show_reward_available(relay_id: String, offer: Dictionary = {}) -> void:
	var event_name := _get_event_display_name(relay_id, offer)
	
	var progress_text := reward_available_text
	
	var to_version := int(offer.get("to_version", offer.get("reward_version", 0)))
	if to_version > 0:
		progress_text += " #" + str(to_version)
	
	_enqueue_message({
		"type": "reward",
		"event_name": event_name,
		"event_progress": progress_text,
		"relay_id" : relay_id
	}, true)


func show_reward_claimed(relay_id: String, offer: Dictionary = {}) -> void:
	var event_name := _get_event_display_name(relay_id, offer)
	
	_enqueue_message({
		"type": "reward",
		"event_name": event_name,
		"event_progress": reward_claimed_text,
		"relay_id" : relay_id
	}, true)


func clear_queue_and_hide() -> void:
	_message_queue.clear()
	_is_running_queue = false
	_active_message_type = ""
	active_displayed_relay_id = ""
	
	_queue_runner_id += 1
	_display_id += 1
	
	if animation_player != null:
		animation_player.stop()


func _enqueue_message(message: Dictionary, urgent: bool = false) -> void:
	if urgent:
		_remove_increment_messages_from_queue()
		
		# Reward messages should appear before pending increment messages.
		_message_queue.push_front(message)
		
		# If an increment popup is currently playing, interrupt it immediately.
		if _active_message_type == "increment":
			_restart_queue_runner()
			return
		
		if not _is_running_queue:
			_start_queue_runner()
		
		return
	
	_message_queue.append(message)
	
	if not _is_running_queue:
		_start_queue_runner()


func _remove_increment_messages_from_queue() -> void:
	var filtered_queue: Array[Dictionary] = []
	
	for message in _message_queue:
		if str(message.get("type", "")) == "increment":
			continue
		
		filtered_queue.append(message)
	
	_message_queue = filtered_queue


func _start_queue_runner() -> void:
	if _message_queue.is_empty():
		return
	
	_queue_runner_id += 1
	var runner_id := _queue_runner_id
	
	_is_running_queue = true
	_run_message_queue(runner_id)


func _restart_queue_runner() -> void:
	_queue_runner_id += 1
	_display_id += 1
	
	var runner_id := _queue_runner_id
	
	_is_running_queue = true
	
	if animation_player != null:
		animation_player.stop()
	
	_run_message_queue(runner_id)


func _run_message_queue(runner_id: int) -> void:
	while runner_id == _queue_runner_id and not _message_queue.is_empty():
		var message: Dictionary = _message_queue.pop_front()
		await _display_message(message, runner_id)
	
	if runner_id == _queue_runner_id:
		_is_running_queue = false
		_active_message_type = ""
		active_displayed_relay_id = ""


func _display_message(message: Dictionary, runner_id: int) -> void:
	_display_id += 1
	var display_id := _display_id
	
	_active_message_type = str(message.get("type", ""))
	active_displayed_relay_id = str(message.get("relay_id", ""))
	
	if event_name_label != null:
		event_name_label.text = str(message.get("event_name", default_event_name))
	
	if event_progress_label != null:
		event_progress_label.text = str(message.get("event_progress", ""))
	
	animation_player.stop()
	animation_player.play(animation_name)
	await animation_player.animation_finished
	
	# This message was interrupted by a newer priority popup.
	if display_id != _display_id:
		return
	
	# This queue runner was replaced by a newer runner.
	if runner_id != _queue_runner_id:
		return
	
	# Any custom actions after the popup is gone can be added here


func _extract_relay_state(data: Dictionary) -> Dictionary:
	if data.has("relay_state") and data.get("relay_state") is Dictionary:
		return data.get("relay_state")
	
	return data


func _get_event_display_name(relay_id: String, data: Dictionary = {}) -> String:
	if data.has("display_name"):
		return str(data.get("display_name"))
	
	if data.has("event_name"):
		return str(data.get("event_name"))
	
	var cleaned := relay_id
	
	if cleaned.begins_with("event."):
		cleaned = cleaned.trim_prefix("event.")
	
	cleaned = cleaned.replace("_", " ")
	cleaned = cleaned.replace("-", " ")
	
	var parts := cleaned.split(" ", false)
	
	for i in range(parts.size()):
		var part := String(parts[i])
		
		if part.length() > 0:
			parts[i] = part.substr(0, 1).to_upper() + part.substr(1)
	
	return " ".join(parts)


## Every meta is treated as the URL pointing to the
## actively displayed event's web page.
func _on_hyperlink_text_meta_clicked(meta: Variant) -> void:
	var link_id = active_displayed_relay_id.substr(active_displayed_relay_id.rfind(".") + 1)
	OS.shell_open("https://lynxrelay.space/events/" + link_id)
