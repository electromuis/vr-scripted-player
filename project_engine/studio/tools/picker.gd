class_name StudioPicker
extends RefCounted

## Which object a ray points at, by maths rather than physics: each
## object's visible meshes give a box in its own space (so it turns and
## scales with it), and the ray is tested against that box. Needs no
## collision shapes on prefabs and runs the same in tests.
##
## A box the ray starts inside (the forest around you, a tunnel you're in)
## only counts when nothing else is hit, and then the smallest such box
## wins; otherwise the nearest hit does.


## The union of `node`'s visible meshes' boxes, in `node`'s own space.
## Meshes under any of `others` (other objects nested inside it) don't
## count: they're picked as themselves. Size zero if there are none.
## Works out of the scene tree too (transforms are chained, not global).
static func local_bounds(node: Node3D, others: Array = []) -> AABB:
	var out := AABB()
	var found := false
	var stack: Array = [[node, Transform3D()]]  # [node, its transform in `node`'s space]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var n: Node = entry[0]
		var xf: Transform3D = entry[1]
		if n != node and others.has(n):
			continue
		if n is Node3D and n != node and not (n as Node3D).visible:
			continue
		if n is VisualInstance3D and not (n is Light3D):
			var box: AABB = xf * (n as VisualInstance3D).get_aabb()
			if box.size != Vector3.ZERO:
				out = box if not found else out.merge(box)
				found = true
		for c in n.get_children():
			stack.append([c, xf * (c as Node3D).transform if c is Node3D else xf])
	return out


## Where the ray (from `origin`, unit `dir`) enters the box `local_box` of
## an object at `object_xf`: {t (metres along the ray), inside (it starts
## in the box)}, or {} if it misses.
static func ray_box(origin: Vector3, dir: Vector3, object_xf: Transform3D, local_box: AABB) -> Dictionary:
	if local_box.size == Vector3.ZERO:
		return {}
	var inv := object_xf.affine_inverse()
	var o := inv * origin
	var d := inv.basis * dir
	if local_box.has_point(o):
		return {"t": 0.0, "inside": true}
	var t_near := -INF
	var t_far := INF
	for axis in 3:
		var lo: float = local_box.position[axis]
		var hi: float = lo + local_box.size[axis]
		if absf(d[axis]) < 1e-9:
			if o[axis] < lo or o[axis] > hi:
				return {}
			continue
		var t1 := (lo - o[axis]) / d[axis]
		var t2 := (hi - o[axis]) / d[axis]
		t_near = maxf(t_near, minf(t1, t2))
		t_far = minf(t_far, maxf(t1, t2))
	if t_near > t_far or t_far < 0.0:
		return {}
	return {"t": maxf(t_near, 0.0), "inside": false}


## The id `candidates` ([{id, xf, bounds}]: the object's global transform
## and its local_bounds) the ray points at, or "". Leave hidden objects out.
static func pick(origin: Vector3, dir: Vector3, candidates: Array) -> String:
	var best := ""
	var best_t := INF
	var inside_best := ""
	var inside_volume := INF
	for c in candidates:
		var xf: Transform3D = c.xf
		var hit := ray_box(origin, dir, xf, c.bounds)
		if hit.is_empty():
			continue
		if hit.inside:
			var box: AABB = c.bounds
			var scale := xf.basis.get_scale()
			var volume := box.size.x * scale.x * box.size.y * scale.y * box.size.z * scale.z
			if volume < inside_volume:
				inside_volume = volume
				inside_best = c.id
		elif hit.t < best_t:
			best_t = hit.t
			best = c.id
	return best if best != "" else inside_best
