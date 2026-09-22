## GoZenPlayer autoload class - exposes GoZenPlayer globally
## This allows instantiating GoZenPlayer via ClassDB.instantiate("GoZenPlayer")

extends Node

func _init() -> void:
	pass

# Helper function to instantiate a GoZenPlayer
func create_player() -> GoZenPlayer:
	return GoZenPlayer.new()