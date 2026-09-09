extends Node

func _ready() -> void:
	var keeper := Node.new()
	keeper.name = "FpsKeeper"
	keeper.set_script(load("res://scripts/debug/fps_runner_persist.gd"))
	get_tree().root.call_deferred("add_child", keeper)
	queue_free()
