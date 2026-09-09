extends Control
## Draws for parent BrainPanel (set `panel` from brain_viz.gd).

var panel: Node


func _draw() -> void:
	if panel and panel.has_method("paint_on"):
		panel.call("paint_on", self)
