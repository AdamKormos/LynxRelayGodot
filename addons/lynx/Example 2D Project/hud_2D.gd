class_name Hud2D extends CanvasLayer



func _process(delta: float) -> void:
	$CoinCount.text = str(Player2D.coin_count).pad_zeros(3)
