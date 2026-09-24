extends SceneTree

## Bakes res://prefabs/forest.tscn: a night-time forest clearing (ground,
## firs as MultiMeshes, floating fireflies). The result is plain data — no
## scripts — so it bundles cleanly into the script folder and the player
## loads it like any prefab (the scene makes its instance a VJ object to fade it).
## Re-run after tweaking the constants:
##
##   godot --path project_script_forest_tunnel --script res://tools/build_forest.gd
##
## Not --headless: the dummy renderer doesn't store MultiMesh buffers, so
## the trees would be saved empty.
##
## Layout assumes the player's home pose: viewer at (0, 2, 8) looking down
## -Z, screen floating around (0, 3, -2). Trees keep clear of that corridor.

const OUT_PATH := "res://prefabs/forest.tscn"
const SEED := 20260922
const TREE_COUNT := 420
const FIREFLY_COUNT := 160
const RADIUS_MIN := 9.0
const RADIUS_MAX := 75.0
const CENTER := Vector2(0.0, 4.0)  # XZ centre of the clearing


func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED

	var root := Node3D.new()
	root.name = "Forest"
	_add(root, root, _ground())

	var trees: Array[Transform3D] = []
	var tints: Array[Color] = []
	while trees.size() < TREE_COUNT:
		var a := rng.randf() * TAU
		# sqrt for an even spread over the annulus area.
		var r := sqrt(lerpf(RADIUS_MIN * RADIUS_MIN, RADIUS_MAX * RADIUS_MAX, rng.randf()))
		var p := CENTER + Vector2(cos(a), sin(a)) * r
		if absf(p.x) < 9.0 and p.y > -8.0 and p.y < 12.0:
			continue  # keep the view to the screen open
		var s := rng.randf_range(0.7, 1.7)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.3), s))
		trees.append(Transform3D(basis, Vector3(p.x, 0.0, p.y)))
		tints.append(Color(0.08, 0.22, 0.12).lerp(Color(0.14, 0.32, 0.16), rng.randf()))

	_add(root, root, _multimesh("Trunks", _trunk_mesh(), trees, []))
	var tiers := [[2.2, 1.5, 3.0], [4.0, 1.1, 2.6], [5.6, 0.7, 2.0]]  # [cone base height, radius, cone height]
	for ti in tiers.size():
		var tier: Array = tiers[ti]
		var xf: Array[Transform3D] = []
		for t in trees:
			xf.append(t * Transform3D(Basis(), Vector3(0.0, tier[0] + tier[2] * 0.5, 0.0)))
		_add(root, root, _multimesh("Canopy%d" % ti, _cone_mesh(tier[1], tier[2]), xf, tints))

	var flies: Array[Transform3D] = []
	for i in FIREFLY_COUNT:
		var a := rng.randf() * TAU
		var r := rng.randf_range(3.0, 30.0)
		var pos := Vector3(cos(a) * r, rng.randf_range(0.4, 4.5), CENTER.y + sin(a) * r)
		flies.append(Transform3D(Basis().scaled(Vector3.ONE * rng.randf_range(0.6, 1.4)), pos))
	_add(root, root, _multimesh("Fireflies", _firefly_mesh(), flies, []))

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err == OK:
		err = ResourceSaver.save(packed, OUT_PATH)
	root.free()
	if err != OK:
		push_error("build_forest: failed (error %d)" % err)
		quit(1)
		return
	print("build_forest: wrote %s (%d trees, %d fireflies)" % [OUT_PATH, trees.size(), flies.size()])
	quit(0)


func _add(root: Node, parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = root


func _ground() -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(200, 200)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.09, 0.05)
	mat.roughness = 1.0
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	mi.mesh = mesh
	mi.position = Vector3(0.0, -0.02, 0.0)  # under the player's optional floor grid
	return mi


func _trunk_mesh() -> Mesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.1
	mesh.bottom_radius = 0.22
	mesh.height = 3.0
	mesh.radial_segments = 8
	mesh.rings = 1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.14, 0.09)
	mesh.material = mat
	return mesh


func _cone_mesh(radius: float, height: float) -> Mesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	mesh.rings = 1
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mesh.material = mat
	return mesh


func _firefly_mesh() -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.035
	mesh.height = 0.07
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.9, 0.4)
	mesh.material = mat
	return mesh


func _multimesh(node_name: String, mesh: Mesh, xforms: Array[Transform3D], colors: Array[Color]) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	return mmi
