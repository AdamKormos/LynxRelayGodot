class_name Hud2D extends CanvasLayer


@export var player : Player2D


func _process(delta: float) -> void:
	$CoinCount.text = str(player.coin_count).pad_zeros(3)
