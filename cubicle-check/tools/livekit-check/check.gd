extends SceneTree
## Starts one godot-livekit check client (client.gd) from outside the project, as run.mjs does:
##   godot --headless --path game -s <repo>/tools/livekit-check/check.gd -- <client.gd's options>


func _init() -> void:
	var client: Node = load(get_script().resource_path.get_base_dir().path_join("client.gd")).new()
	root.add_child.call_deferred(client)
