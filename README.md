# Lynx

[Website](https://lynxrelay.space)

[Discord Community](https://discord.gg/xXzVDY5ShU)

**Lynx** is a Godot plugin for shared community events.

Players contribute to a global online event counter from inside your game.  
When the community reaches a goal, your game can unlock rewards for players.

Example:

```text
All players collect coins together.
The shared goal reaches 1000.
A reward chest becomes available in every player's game.
```

Lynx is built for indie games that want lightweight online community events without building a full custom backend from scratch.

---

## Features

- Shared online event counters
- Simple autoload API
- Reward availability detection
- Safe reward claim flow
- `LynxHandler` helper interface for handling event UI, rewards, and player interactions
- Global popup UI for event updates and reward notifications
- Dynamic goals with growth multipliers
- Example 2D project

---

## Status

Lynx is currently in **alpha / early access**.

APIs and backend behavior may still change. Use it for prototypes, tests, game jams, and early integrations.

---

## Installation & Setup

### 0. Get your game registered

The API regulates usage to verified games, using an identifier system. To register your game, join our [Discord community](https://discord.gg/xXzVDY5ShU) and see the instructions in the #how-to-join channel.

### 1. Download the repository and add the _res://addons/lynx_ folder into your Godot project, to the same folder path:
<img width="342" height="380" alt="Screenshot_1" src="https://github.com/user-attachments/assets/8c8dc9cf-698a-471e-b80f-8879e9aa8a53" />

### 2. Enable the plugin inside Godot:

```text
Project -> Project Settings -> Plugins -> Lynx -> Enable
```

The plugin automatically adds these autoloads:

```text
LynxRelay
LynxRewards
LynxEventPopup
```

### 3. Configure your game identifiers:

After registering your game to Lynx, you receive a public Game ID, a runtime Game Key, and a private Game Admin Password. Put only the Game ID and Game Key in the Godot project. Keep the Game Admin Password out of exported builds and public repositories.
Open the Lynx client script and update the following variables:

```gdscript
const GAME_ID := "your-game-id"
const GAME_KEY := "your-game-key"
```

Do not commit a real Game Admin Password to a public repository. The Game Key is a runtime credential, not an admin password, but you can still rotate it from the admin tools if it is abused.

### 4. Recommended interface: LynxHandler

For most games, the easiest way to use Lynx is through `LynxHandler`.

`LynxHandler` is a small interface node that connects the Lynx signals for you and gives you simple functions to override in your own game.

Use it to handle:

- event counter UI updates
- player contributions
- reward availability
- reward object spawning
- reward claim start / success / failure

An example use case can be seen in the sample 2D project, available within this repository's _res://addons/lynx/Example 2D Project_.
Instead of wiring every signal manually, extend `LynxHandler` and override the parts your game needs:

```gdscript
extends LynxHandler


@onready var counter_label: Label = %CounterLabel
@onready var reward_chest: Node2D = %RewardChest


func update_goal_state_visuals(relay_state: Dictionary) -> void:
	var value := int(relay_state.get("value", 0))
	var target := int(relay_state.get("target", 0))

	counter_label.text = str(value) + "/" + str(target)


func display_reward_item(offer: Dictionary) -> void:
	reward_chest.visible = true


func on_player_reward_claim_success() -> void:
	reward_chest.visible = false

	# Give your reward here.
	# Example:
	# player_inventory.add_item("community_chest")
```

Set which event the handler listens to:

```gdscript
@export var listened_event: String = "sunfall"
```

`LynxHandler` is the recommended starting point. You can still use `LynxRelay` and `LynxRewards` directly if you want full control.

---

## Requirements in integration

After your game is verified, you receive your game credentials. We ask you to keep the following requirements in mind:

- You will represent at least one event in your game, and grant any kind of reward per goal (doesn't need to make the player "powerful" per se, anything is good!).
- The UI popup (read more below) displays correctly in your game, both in case of the player contributing to the goal, and the reward becoming available - but you are free to customize the layout and appearance of this box.
- Your game supports the ability to open a hyperlink of each event counter, where participating games of the event are also listed. This hyperlink button is available on the UI popup by clicking, but you can bind a keybind to it otherwise.
- If you're exporting to Android, make sure to enable Internet permissions on your export settings! If this is not done, the plugin cannot function.
- Do not spam or abuse any events. If you do so, your access will be revoked. This is just a common sense rule - don't push an increment every game frame, don't spam the server etc. The plugin code already handles streamlined communication.
- Rewards are claimed using highest-tier policy (described under the Claiming a Reward section). This just means you don't modify the existing plugin code to behave otherwise.

---

## Basic Usage

### Add progress to an event

Call this when the player does something that should contribute to the community goal:

```gdscript
await LynxRelay.increment_relay("sunfall", 1)
```

Example:

```gdscript
func _on_coin_collected() -> void:
	await LynxRelay.increment_relay("sunfall", 1)
```

---

## Reading Event Progress

Sync the event state:

```gdscript
var result := await LynxRelay.sync_relay("sunfall")

if result.get("ok", false):
	var state: Dictionary = result.get("relay_state", {})
	var value := int(state.get("value", 0))
	var target := int(state.get("target", 0))

	print(value, "/", target)
```

Example UI:

```gdscript
counter_label.text = str(value) + "/" + str(target)
```

---

## Listening for Updates Manually

You can also connect to Lynx signals yourself:

```gdscript
func _ready() -> void:
	LynxRelay.sync_completed.connect(_on_sync_completed)
	LynxRelay.increment_completed.connect(_on_increment_completed)
	LynxRewards.offer_available.connect(_on_reward_available)
```

```gdscript
func _on_sync_completed(relay_id: String, relay_state: Dictionary, claim: Dictionary) -> void:
	if relay_id != "sunfall":
		return

	var value := int(relay_state.get("value", 0))
	var target := int(relay_state.get("target", 0))

	counter_label.text = str(value) + "/" + str(target)
```

---

## Rewards

When a community goal is reached, Lynx can create a reward offer.

Listen for it:

```gdscript
func _ready() -> void:
	LynxRewards.offer_available.connect(_on_reward_available)
```

```gdscript
func _on_reward_available(relay_id: String, offer: Dictionary) -> void:
	if relay_id != "sunfall":
		return

	reward_chest.visible = true
```

With `LynxHandler`, you usually only need to override `display_reward_item()`:

```gdscript
func display_reward_item(offer: Dictionary) -> void:
	reward_chest.visible = true
```

---

## Claiming a Reward

When the player interacts with your reward object:

```gdscript
func claim_reward() -> void:
	if not LynxRewards.has_offer("sunfall"):
		return

	var result := await LynxRewards.prepare_offer_claim("sunfall")

	if result.get("superseded", false):
		return

	if not result.get("ok", false):
		print("Reward claim failed: ", result)
		return

	# Give your reward here.
	# Example:
	# player_inventory.add_item("community_chest")

	# Save your game before completing the offer.
	# SaveGame.save()

	LynxRewards.complete_offer("sunfall")
```

The important order is:

```text
prepare -> give reward -> save game -> complete
```

This helps avoid duplicate or lost rewards.

Lynx currently follows a policy of granting the highest-tier reward only. Assume that a player claimed the reward after reaching the goal for the 1st time, but they don't play for a while. Now, they run the game again and even the 3rd goal has been reached. In this case, this player only claims the 3rd goal's reward.
Players have no access to rewards prior to their first play session.

If you use `LynxHandler`, the sample handler already follows this flow and calls:

```gdscript
on_player_reward_claim_start()
on_player_reward_claim_success()
on_player_reward_claim_fail()
```

Override those functions to connect Lynx reward claiming to your own game logic.

---

## Popup UI

Lynx includes a global popup UI for event updates and reward notifications.

It can show when:

- the local player contributes to an event counter
- a community reward becomes available
- a reward is claimed

Example calls:

```gdscript
LynxEventPopup.show_counter_contribution("sunfall", 1, relay_state)
LynxEventPopup.show_reward_available("sunfall", offer)
LynxEventPopup.show_reward_claimed("sunfall", offer)
```

The popup is a normal Godot scene, so you can restyle or replace it for your own game.

The default popup uses:

```text
CanvasLayer
AnimationPlayer
RichTextLabel for event name
RichTextLabel for event progress
```

The default animation name is:

```text
Display
```

The `Display` animation should handle the full visual movement:

```text
enter -> stay -> exit
```

Do not animate the `text` property of the popup labels, otherwise the animation may overwrite the text set by the script.

---

## Example Project

The repository includes a small 2D example showing:

- contributing to an event
- displaying progress
- using `LynxHandler`
- showing reward availability
- claiming a reward
- using the popup UI

Look in:

```text
addons/lynx/Example 2D Project/
```

---

## Dynamic Goals

Lynx supports growing goals.

Example:

```text
Goal 1: 100
Goal 2: 220
Goal 3: 364
```

This lets community events become harder over time.

The Godot plugin automatically receives the current target from the backend.

---

## Security Notes

Do not publish:

- admin tokens
- backend secrets
- private API keys
- Cloudflare secrets
- payment keys

Game Keys are runtime credentials and may be included in game builds, but public examples should use placeholders.

Game Admin Passwords must never be included in game clients, exported builds, public repositories, screenshots, logs, or support messages.

---

## Roadmap

Planned improvements:

- easier editor configuration
- better sample scenes
- hosted dashboard
- more popup themes
- Godot Asset Library release
- improved backend documentation

---

## License

MIT License.

---

## Credits

Created by Ádám Kormos.
