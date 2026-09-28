extends Node
## Headless behavioural self-test for the football match (PHASE 20).
##
## It drives the SAME code paths the on-screen controls drive - it sets the
## thumb-stick vector and the PASS/SHOOT button flags on the TouchControls node,
## never the footballer's internals - then prints one [AUTOTEST] line per claim
## so the runtime behaviour can be read back from the console.
##
## It is only instantiated while MatchSelfTest.ENABLED is on, and it is deleted
## from the project once the match has been validated.

const STEP_IDLE: int = 0
const STEP_JOYSTICK: int = 1
const STEP_POSSESS: int = 2
const STEP_PASS: int = 3
const STEP_SHOOT: int = 4
const STEP_SWITCH: int = 5
const STEP_AI: int = 6
const STEP_REST: int = 7
const STEP_DONE: int = 8

var _match: Node3D
var _touch: Node
var _ball: Node3D
var _human: Node3D

var _t: float = 0.0
var _step: int = STEP_IDLE
var _frame: int = 0

# Recorded measurements.
var _ball_max_y: float = 0.0
var _ball_max_jump: float = 0.0
var _prev_ball_pos: Vector3 = Vector3.ZERO
var _ignore_jump: int = 0
var _max_player_y: float = 0.0
var _possession_changes: int = 0
var _last_owner: Node3D = null
var _drift_start: Vector3 = Vector3.ZERO
var _move_start: Vector3 = Vector3.ZERO
var _follow_samples: int = 0
var _follow_max: float = 0.0
var _pass_speed: float = -1.0
var _pass_lift: float = -1.0
var _shoot_speed: float = -1.0
var _shoot_vz: float = 0.0
var _aiming: bool = false
var _shoot_z0: float = 0.0
var _shoot_z1: float = 0.0
var _ai_start: Dictionary = {}
var _ai_total: float = 0.0
var _switch_changed: bool = false
var _switch_count: int = -1
var _rest_start: Vector3 = Vector3.ZERO
var _rest_nearest: float = 0.0
var _rest_min: float = 9999.0
var _pass_owner_cleared: bool = false
var _pass_p0: Vector3 = Vector3.ZERO
var _pass_t0: float = 0.0
var _shoot_released: bool = false
var _shoot_p0: Vector3 = Vector3.ZERO
var _shoot_t0: float = 0.0
var _shoot_vy: float = 0.0
var _possess_ok: bool = false
var _armed: bool = false
## Peak flat speed reached while the thumb-stick is held, and how much of that
## window play was actually enabled for.
var _move_peak: float = 0.0
var _move_play_time: float = 0.0


func _ready() -> void:
	begin(get_parent())


func begin(match_node: Node3D) -> void:
	_match = match_node
	_touch = match_node.get_node_or_null("HUD/TouchControls")
	_ball = match_node.get_node_or_null("Ball")
	_human = _find_human()
	if _touch == null or _ball == null or _human == null:
		print("[AUTOTEST] ABORT missing touch=%s ball=%s human=%s" % [str(_touch != null), str(_ball != null), str(_human != null)])
		_step = STEP_DONE
		return
	_prev_ball_pos = _ball.global_position
	print("[AUTOTEST] START human=%s" % _human.name)


func _find_human() -> Node3D:
	for f in get_tree().get_nodes_in_group("footballers"):
		if f.human_controlled:
			return f
	return null


func _physics_process(delta: float) -> void:
	if _step == STEP_DONE:
		return
	_t += delta
	_frame += 1
	_track()

	match _step:
		STEP_IDLE:
			if _t >= 1.6:
				_js(0.0, 0.0, false)
				_drift_start = _human.global_position
				_step = STEP_JOYSTICK
		STEP_JOYSTICK:
			if _armed == false and _t >= 3.0:
				_armed = true
				var drift: float = _flat(_human.global_position, _drift_start)
				print("[AUTOTEST] RESULT no_input_drift=%.2f m (want < 0.30)" % drift)
				_move_start = _human.global_position
				_js(0.0, -1.0, true)  # straight "forward" on the stick
			elif _armed:
				# Peak speed while the stick is held is the honest movement number:
				# a goal somewhere else on the pitch can freeze play for a moment
				# without hiding whether the human actually accelerates.
				if bool(_human.can_play):
					_move_play_time += delta
					_move_peak = maxf(_move_peak, _flat_speed(_human.velocity))
				if _t >= 4.5:
					var moved: float = _flat(_human.global_position, _move_start)
					print("[AUTOTEST] RESULT joystick_move=%.2f m peak_speed=%.2f m/s play_window=%.2f s (want move > 1.00, peak > 4.00)" % [moved, _move_peak, _move_play_time])
					_place_ball_at_feet(1.0)
					_armed = false
					_step = STEP_POSSESS
		STEP_POSSESS:
			if _armed == false and _t >= 5.5:
				_armed = true
				_possess_ok = _ball.ball_owner == _human
				print("[AUTOTEST] RESULT possession_acquired=%s owner=%s" % [str(_possess_ok), str(_ball.ball_owner.name if _ball.ball_owner != null else "none")])
			elif _armed and _t >= 6.4:
				var gap: float = _flat(_ball.global_position, _human.global_position)
				print("[AUTOTEST] RESULT ball_at_feet_gap=%.2f m (want < 2.50) samples=%d peak=%.2f" % [gap, _follow_samples, _follow_max])
				_touch.pass_down = true
				_armed = false
				_step = STEP_PASS
		STEP_PASS:
			if _armed == false and _t >= 6.4:
				_armed = true
			if _armed:
				if _t >= 6.6:
					_touch.pass_down = false
				# A direct velocity read on the kick frame reports the OLD speed. The
				# `pass` tag is set by `launch()` on the exact frame the ball is
				# struck, so gating on it reads the true struck velocity. Then measure
				# how far the ball actually travelled - that is unfakeable.
				if int(_ball.get("state")) == 2 and not _pass_owner_cleared:
					_pass_owner_cleared = true
					_pass_p0 = _ball.global_position
					_pass_t0 = _t
					var v: Vector3 = _ball.linear_velocity
					_pass_speed = Vector2(v.x, v.z).length()
					_pass_lift = v.y
				elif _pass_owner_cleared and _t >= _pass_t0 + 0.5:
					var travel: float = _flat(_ball.global_position, _pass_p0)
					print("[AUTOTEST] RESULT pass speed=%.2f m/s lift=%.2f travel=%.2f m in 0.50 s released=%s (want speed > 8.00, lift < 1.00, travel > 3.00, released true)" % [_pass_speed, _pass_lift, travel, str(_pass_owner_cleared)])
					_place_ball_at_feet(1.0)
					_armed = false
					_step = STEP_SHOOT
		STEP_SHOOT:
			if not _aiming and not _armed and _t >= 7.6:
				# Push the stick away from the camera so the player faces the red
				# goal before shooting, exactly as a thumb would.
				_js(0.0, -1.0, true)
				_aiming = true
			elif _aiming and _t >= 8.0:
				_aiming = false
				_place_ball_at_feet(1.0)
				_shoot_z0 = _ball.global_position.z
				_armed = true
				_touch.shoot_down = true
			elif _armed:
				if _t >= 8.9:
					_touch.shoot_down = false
				# Same as the pass: gate on the `shooting` tag that `launch()` sets on
				# the struck frame, then measure the distance actually covered.
				if int(_ball.get("state")) == 3 and not _shoot_released:
					_shoot_released = true
					_shoot_p0 = _ball.global_position
					_shoot_t0 = _t
					var v2: Vector3 = _ball.linear_velocity
					_shoot_speed = Vector2(v2.x, v2.z).length()
					_shoot_vz = v2.z
					_shoot_vy = v2.y
				elif _shoot_released and _t >= _shoot_t0 + 0.5:
					var travel2: float = _flat(_ball.global_position, _shoot_p0)
					print("[AUTOTEST] RESULT shoot speed=%.2f m/s vz=%.2f vy=%.2f travel=%.2f m in 0.50 s (want speed > 8.00, vz < 0 toward red goal, vy < 3.00)" % [_shoot_speed, _shoot_vz, _shoot_vy, travel2])
					_js(0.0, 0.0, false)
					_switch_before()
					_step = STEP_SWITCH
		STEP_SWITCH:
			if _t >= 9.7:
				_match.call("_cycle_selection")
				_switch_after()
				_step = STEP_AI
				_ai_snapshot()
		STEP_AI:
			if _t >= 12.7:
				_ai_total = _ai_travel()
				print("[AUTOTEST] RESULT ai_moved_total=%.2f m over 3.0 s, no ball involvement required (want > 3.00)" % _ai_total)
				_shoot_z1 = _ball.global_position.z
				print("[AUTOTEST] RESULT shoot_ball_travel_dz=%.2f m (negative = travelled toward the red goal)" % (_shoot_z1 - _shoot_z0))
				_place_ball_far()
				_step = STEP_REST
		STEP_REST:
			if _t >= 13.5:
				var rest: float = _flat(_ball.global_position, _rest_start)
				print("[AUTOTEST] RESULT loose_ball_drift=%.2f m over 0.8 s (closest any player came %.2f m; want drift < 0.60 while nobody is within 1.25 m)" % [rest, _rest_min])
				_finish()


# ----------------------------------------------------------------------------
# Drive the on-screen controls exactly as a thumb would
# ----------------------------------------------------------------------------

func _js(x: float, y: float, active: bool) -> void:
	_touch.stick_active = active
	_touch.move_vector = Vector2(x, y)


func _place_ball_at_feet(ahead: float) -> void:
	_ignore_jump = 3
	var f: Vector3 = _human.global_position + _flat_forward(_human) * ahead
	_ball.call("reset_to", Vector3(f.x, 0.3, f.z))
	_prev_ball_pos = _ball.global_position


func _place_ball_far() -> void:
	_ignore_jump = 3
	_ball.call("reset_to", Vector3(-9.0, 0.3, 12.0))
	_prev_ball_pos = _ball.global_position
	_rest_start = _ball.global_position
	_rest_nearest = _nearest_player_distance(_ball.global_position)
	_rest_min = _rest_nearest


# ----------------------------------------------------------------------------
# Measurement
# ----------------------------------------------------------------------------

func _track() -> void:
	var bp: Vector3 = _ball.global_position
	_ball_max_y = maxf(_ball_max_y, bp.y)
	var jump: float = bp.distance_to(_prev_ball_pos)
	if _ignore_jump > 0:
		_ignore_jump -= 1
	elif not _kickoff_locked():
		# Kickoff deliberately puts the ball back on the centre spot; that is a
		# restart, not a physics teleport, so it must not count here.
		_ball_max_jump = maxf(_ball_max_jump, jump)
	_prev_ball_pos = bp

	for f in get_tree().get_nodes_in_group("footballers"):
		_max_player_y = maxf(_max_player_y, f.global_position.y)

	var owner = _ball.ball_owner
	if owner != _last_owner:
		if _last_owner != null or owner != null:
			_possession_changes += 1
		_last_owner = owner

	# While the ball sits loose, remember how close any player ever came, so a
	# drift reading can be read against whether somebody was actually on it.
	if _step == STEP_REST:
		_rest_min = minf(_rest_min, _nearest_player_distance(bp))

	# How far the ball sits from the human while it is being carried.
	if _step == STEP_POSSESS and owner == _human:
		_follow_samples += 1
		_follow_max = maxf(_follow_max, _flat(bp, _human.global_position))


## True while a kickoff or restart is in progress, when the ball is deliberately
## returned to the centre spot. That reset is not a gameplay teleport.
func _kickoff_locked() -> bool:
	if _match == null:
		return false
	return bool(_match.get("_goal_lock"))


func _ai_snapshot() -> void:
	_ai_start.clear()
	for f in get_tree().get_nodes_in_group("footballers"):
		if f.human_controlled:
			continue
		_ai_start[f] = f.global_position


func _ai_travel() -> float:
	var total: float = 0.0
	for f in _ai_start.keys():
		if not is_instance_valid(f):
			continue
		total += _flat(f.global_position, _ai_start[f])
	return total


func _switch_before() -> void:
	_switch_count = _human_count()
	_switch_changed = false
	_pre_switch = _human


var _pre_switch: Node3D


func _switch_after() -> void:
	var now_human := _find_human()
	_switch_changed = now_human != null and now_human != _pre_switch
	print("[AUTOTEST] RESULT switch changed=%s count_now=%d count_before=%d (exactly 1 required)" % [str(_switch_changed), _human_count(), _switch_count])


func _human_count() -> int:
	var n: int = 0
	for f in get_tree().get_nodes_in_group("footballers"):
		if f.human_controlled:
			n += 1
	return n


func _nearest_player_distance(point: Vector3) -> float:
	var best: float = 1.0e9
	for f in get_tree().get_nodes_in_group("footballers"):
		best = minf(best, _flat(f.global_position, point))
	return best


func _finish() -> void:
	var bounds_ok: bool = _check_bounds()
	print("[AUTOTEST] RESULT ball_max_height=%.2f m (want < 1.50, never flies)" % _ball_max_y)
	print("[AUTOTEST] RESULT ball_max_frame_jump=%.2f m (want < 1.00, no teleports)" % _ball_max_jump)
	print("[AUTOTEST] RESULT possession_changes=%d players_below_ceiling=%s" % [_possession_changes, str(_max_player_y < 3.0)])
	print("[AUTOTEST] RESULT players_in_bounds=%s" % str(bounds_ok))
	print("[AUTOTEST] DONE")
	_step = STEP_DONE


## PHASE 16/17: nobody leaves the pitch, nothing falls out of the world.
func _check_bounds() -> bool:
	var ok: bool = true
	for f in get_tree().get_nodes_in_group("footballers"):
		var p: Vector3 = f.global_position
		if absf(p.x) > 11.9 or absf(p.z) > 17.9 or p.y < -0.5 or p.y > 3.0:
			print("[AUTOTEST] BOUNDS_FAIL %s at (%.1f, %.1f, %.1f)" % [f.name, p.x, p.y, p.z])
			ok = false
	var b: Vector3 = _ball.global_position
	if absf(b.x) > 12.9 or absf(b.z) > 18.9 or b.y < -1.0:
		print("[AUTOTEST] BOUNDS_FAIL ball at (%.1f, %.1f, %.1f)" % [b.x, b.y, b.z])
		ok = false
	return ok


func _flat_forward(who: Node3D) -> Vector3:
	var dir: Vector3 = who.velocity
	if dir.length_squared() < 0.01:
		return Vector3(0.0, 0.0, -1.0)
	return Vector3(dir.x, 0.0, dir.z).normalized()


func _flat_speed(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _flat(a: Vector3, b: Vector3) -> float:
	var dx: float = b.x - a.x
	var dz: float = b.z - a.z
	return sqrt(dx * dx + dz * dz)
