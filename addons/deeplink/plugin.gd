@tool
extends EditorPlugin

var _export := preload("res://addons/deeplink/export_plugin.gd").new()


func _enter_tree() -> void:
	add_export_plugin(_export)


func _exit_tree() -> void:
	remove_export_plugin(_export)
