class_name CoinGetArea2D extends Area2D


signal coin_claim_ready


func _on_body_entered(body: Node2D) -> void:
	if body is Player2D:
		coin_claim_ready.emit()
		# You DON'T do this here:
		# body.coin_count += 1
		# This will be performed after Lynx confirms the reward has been claimed
