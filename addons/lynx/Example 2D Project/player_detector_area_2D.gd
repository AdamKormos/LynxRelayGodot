class_name PlayerDetectorArea2D extends Area2D


func _on_body_entered(body: Node2D) -> void:
	if body is Player2D:
		LynxRelay.increment_relay("devtest", 10)
