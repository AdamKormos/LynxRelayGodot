@tool
extends EditorPlugin


const ADDON_ROOT := "res://addons/lynx/"

const AUTOLOADS := [
	{
		"name": "LynxRelay",
		"path": ADDON_ROOT + "lynx_relay_client.gd",
		"required": true
	},
	{
		"name": "LynxRewards",
		"path": ADDON_ROOT + "lynx_reward_offer_manager.gd",
		"required": true
	},
	{
		"name": "LynxEventPopup",
		"path": ADDON_ROOT + "lynx_event_popup.tscn",
		"required": true
	}
]


func _enable_plugin() -> void:
	for autoload_data in AUTOLOADS:
		_add_lynx_autoload(autoload_data)
	
	_save_project_settings()


func _disable_plugin() -> void:
	for i in range(AUTOLOADS.size() - 1, -1, -1):
		var autoload_data: Dictionary = AUTOLOADS[i]
		_remove_lynx_autoload(autoload_data)
	
	_save_project_settings()


func _add_lynx_autoload(autoload_data: Dictionary) -> void:
	var autoload_name := str(autoload_data.get("name", ""))
	var autoload_path := str(autoload_data.get("path", ""))
	var is_required := bool(autoload_data.get("required", true))
	
	if autoload_name.is_empty():
		push_error("Lynx plugin: Cannot add autoload with empty name.")
		return
	
	if autoload_path.is_empty():
		push_error("Lynx plugin: Cannot add autoload '%s' with empty path." % autoload_name)
		return
	
	if not ResourceLoader.exists(autoload_path):
		var message := "Lynx plugin: Autoload file not found: %s" % autoload_path
		
		if is_required:
			push_error(message)
		else:
			push_warning(message)
		
		return
	
	if _autoload_exists(autoload_name):
		var existing_path := _get_autoload_path(autoload_name)
		
		if _same_resource_path(existing_path, autoload_path):
			print("Lynx plugin: Autoload already configured: %s -> %s" % [autoload_name, autoload_path])
			return
		
		push_warning(
			"Lynx plugin: Autoload name '%s' already exists at '%s'. Not overriding it with '%s'."
			% [autoload_name, existing_path, autoload_path]
		)
		return
	
	add_autoload_singleton(autoload_name, autoload_path)
	
	print("Lynx plugin: Added autoload: %s -> %s" % [autoload_name, autoload_path])


func _remove_lynx_autoload(autoload_data: Dictionary) -> void:
	var autoload_name := str(autoload_data.get("name", ""))
	var expected_path := str(autoload_data.get("path", ""))
	
	if autoload_name.is_empty():
		return
	
	if not _autoload_exists(autoload_name):
		return
	
	var existing_path := _get_autoload_path(autoload_name)
	
	if not _same_resource_path(existing_path, expected_path):
		push_warning(
			"Lynx plugin: Autoload '%s' exists, but it does not point to this plugin. Keeping it. Existing: '%s', expected: '%s'."
			% [autoload_name, existing_path, expected_path]
		)
		return
	
	remove_autoload_singleton(autoload_name)
	
	print("Lynx plugin: Removed autoload: %s" % autoload_name)


func _autoload_exists(autoload_name: String) -> bool:
	return ProjectSettings.has_setting(_get_autoload_setting_key(autoload_name))


func _get_autoload_path(autoload_name: String) -> String:
	var key := _get_autoload_setting_key(autoload_name)
	
	if not ProjectSettings.has_setting(key):
		return ""
	
	var value := str(ProjectSettings.get_setting(key))
	
	return _normalize_autoload_path(value)


func _get_autoload_setting_key(autoload_name: String) -> String:
	return "autoload/" + autoload_name


func _normalize_autoload_path(path: String) -> String:
	var normalized := path.strip_edges()
	
	# Godot stores singleton autoloads in project.godot like:
	# LynxRelay="*res://addons/lynx/lynx_relay_client.gd"
	if normalized.begins_with("*"):
		normalized = normalized.substr(1)
	
	return normalized


func _same_resource_path(a: String, b: String) -> bool:
	return _normalize_autoload_path(a) == _normalize_autoload_path(b)


func _save_project_settings() -> void:
	var error := ProjectSettings.save()
	
	if error != OK:
		push_warning("Lynx plugin: ProjectSettings.save() failed with error code: %s" % str(error))
