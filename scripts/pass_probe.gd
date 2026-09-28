extends Node
## TEMPORARY isolated pass probe (validation only, deleted once the bug is fixed).
##
## It parks the controlled player alone in the south half with the ball at the
## feet, waits for genuine possession, fires exactly one PASS through the same
## `_human_pass()` the touch button calls, then prints one line per physics frame
## showing the ball's velocity, position, owner and how far the nearest other
## body is. `dot_to_kicker` is the smoking gun: +1.00 means the pass was aimed
## straight back into the kicker's own body.

const SAMPLE_FRAMES: int = 30

var _match: Node3D
var _ball: RigidBody3D
var _human: Node3D

var _t: float = 0.0
var _after: int = -1
var _p0: Vector3 = Vector3.ZERO
var _done: bool = false


func begin(match_node: Node3D) -> void:
	_match = match_node
	_ball = match_node.get_node_or_null("Ball") as RigidBody3D
	for f in get_tree().get_nodes_in_group("footballers"):
		if f.human_controlled:
			_human = f
	if _human == null or _ball == null:
		print("[PASS] ABORT missing human or ball")
		_done = true
		return
	print("[PASS] START human=%s" % _human.name)


func _physics_process(delta: float) -> void:
	if _done:
		return
	_t += delta
	_hold_still()

	if _after < 0:
		if _t < 0.30:
			return
		if _t < 0.40:
			_human.global_position = Vector3(0.0, 0.15, 10.0)
			_ball.call("reset_to", Vector3(0.0, 0.30, 9.0))
			return
		if _ball.ball_owner == _human and _t > 0.55:
			_fire()
		elif _t > 4.0:
			print("[PASS] ABORT never possessed, owner=%s" % _owner_name())
			_done = true
		return

	_after += 1
	var nearest: float = _nearest_body_distance(_ball.global_position)
	print("[PASS] f=%02d state=%d owner=%s v=(%.2f,%.2f,%.2f) pos=(%.2f,%.2f,%.2f) nearest_body=%.2f" % [
		_after, int(_ball.get("state")), _owner_name(),
		_ball.linear_velocity.x, _ball.linear_velocity.y, _ball.linear_velocity.z,
		_ball.global_position.x, _ball.global_position.y, _ball.global_position.z,
		nearest,
	])
	if _after >= SAMPLE_FRAMES:
		var travel: float = _flat(_ball.global_position, _p0)
		print("[PASS] RESULT travel=%.2f m over %d frames (want > 2.00 if unobstructed)" % [travel, SAMPLE_FRAMES])
		_done = true


## Fire exactly one pass through the same path the PASS button uses, and report
## where the ball was, where the kicker was, and whether the launch direction
## pointed back into the kicker.
func _fire() -> void:
	var bp: Vector3 = _ball.global_position
	var hp: Vector3 = _human.global_position
	_p0 = bp
	_human.call("_human_pass")
	var v: Vector3 = _ball.linear_velocity
	var sep: Vector3 = bp - hp
	sep.y = 0.0
	var dot: float = 0.0
	if sep.length() > 0.01 and Vector2(v.x, v.z).length() > 0.01:
		var flat_v := Vector3(v.x, 0.0, v.z).normalized()
		dot = flat_v.dot(-sep.normalized())
	print("[PASS] FIRE sep=%.2f launch_v=(%.2f,%.2f,%.2f) speed=%.2f dot_to_kicker=%.2f" % [
		sep.length(), v.x, v.y, v.z, Vector2(v.x, v.z).length(), dot,
	])
	_after = 0


func _hold_still() -> void:
	var touch = _match.get_node_or_null("HUD/TouchControls")
	if touch == null:
		return
	touch.stick_active = false
	touch.move_vector = Vector2.ZERO


func _owner_name() -> String:
	var owner = _ball.ball_owner
	if owner == null or not is_instance_valid(owner):
		return "none"
	return String(owner.name)


func _nearest_body_distance(point: Vector3) -> float:
	var best: float = 1.0e9
	for f in get_tree().get_nodes_in_group("footballers"):
		var d: float = _flat(f.global_position, point)
		if d > 0.01:
			best = minf(best, d)
	return best


func _flat(a: Vector3, b: Vector3) -> float:
	var dx: float = b.x - a.x
	var dz: float = b.z - a.z
	return sqrt(dx * dx + dz * dz)
