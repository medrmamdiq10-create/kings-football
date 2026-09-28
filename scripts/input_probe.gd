extends Node
## Behavioural validation harness for the human input path (validation only).
##
## It drives the SAME flags the on-screen controls drive - the thumb-stick vector
## and the PASS / SHOOT / SWITCH button states on the TouchControls node - and
## nothing else. It never teleports the ball, never resets it, never writes a
## footballer's internals and never writes physics state. It only reads back what
## the game did and prints one [INPUT] line per claim.
##
## Between the strike tests it CHASES the ball with the stick, exactly as a player
## would, because a striker who is nowhere near the ball cannot strike it - that
## is a real gameplay rule this probe must respect rather than work around.
##
## It waits for kickoff to finish before the first test: during the kickoff freeze
## play is legitimately disabled, so a measurement taken then would be nonsense.

const P_WAIT: int = 0
const P_JOY: int = 1
const P_INDICATOR: int = 2
const P_SWITCH: int = 3
const P_ACQUIRE: int = 4
const P_PASS: int = 5
const P_PASS_WAIT: int = 6
const P_SHOOT_AIM: int = 7
const P_SHOOT: int = 8
const P_SHOOT_WAIT: int = 9
const P_DONE: int = 10

const JOY_TIME: float = 1.2
const STRIKE_WINDOW: float = 0.5

var _match: Node = null
var _touch: Node = null
var _ball: Node3D = null
var _human: Node3D = null

var _phase: int = P_WAIT
var _t: float = 0.0

var _joy_start: Vector3 = Vector3.ZERO
var _joy_peak: float = 0.0
var _joy_play: float = 0.0

var _ind_bad: int = 0
var _ind_min: int = 99
var _ind_max: int = 0

var _pre_switch: Node3D = null

var _own_at_strike: String = ""
var _peak_speed: float = 0.0
var _strike_start: Vector3 = Vector3.ZERO
var _acquire_clock: float = 0.0
var _acquire_label: String = ""
## Every result line is also written to a file, because the editor console keeps
## only a handful of messages and would otherwise hide the later results.
var _lines: Array[String] = []


func _emit(line: String) -> void:
	_lines.append(line)
	print(line)


func begin(match_node: Node) -> void:
	_match = match_node
	_touch = match_node.get_node_or_null("HUD/TouchControls")
	_ball = match_node.get_node_or_null("Ball")
	_refresh_human()
	if _touch == null or _ball == null or _human == null:
		print("[INPUT] ABORT missing touch=%s ball=%s human=%s" % [
			str(_touch != null), str(_ball != null), str(_human != null),
		])
		_phase = P_DONE
		return
	_js(0.0, 0.0, false)
	print("[INPUT] START human=%s" % String(_human.name))


func _refresh_human() -> void:
	for f in get_tree().get_nodes_in_group("footballers"):
		if is_instance_valid(f) and bool(f.human_controlled):
			_human = f
			return


func _physics_process(delta: float) -> void:
	if _phase == P_DONE:
		return
	_t += delta
	match _phase:
		P_WAIT:
			# Kickoff disables play for a moment; measuring movement or a strike
			# during that freeze would report a broken control that is not broken.
			if _human != null and bool(_human.can_play) and _t >= 0.8:
				print("[INPUT] play enabled at t=%.2f s" % _t)
				_js(0.0, -1.0, true)
				_joy_start = _human.global_position
				_joy_peak = 0.0
				_joy_play = 0.0
				_go(P_JOY)
		P_JOY:
			_js(0.0, -1.0, true)
			if bool(_human.can_play):
				_joy_play += delta
				_joy_peak = maxf(_joy_peak, _flat_speed_of(_human.velocity))
			if _t >= JOY_TIME:
				var moved: float = _flat(_human.global_position, _joy_start)
				_emit("[INPUT] RESULT joystick_move=%.2f m peak_speed=%.2f m/s play_window=%.2f s - want move > 1.00 and peak > 4.00, the stick must drive the controlled player" % [moved, _joy_peak, _joy_play])
				_js(0.0, 0.0, false)
				_go(P_INDICATOR)
		P_INDICATOR:
			_count_indicators()
			if _t >= 0.4:
				_emit("[INPUT] RESULT indicator_visible=%d..%d bad_samples=%d - want 1..1 and 0, exactly one triangle on the controlled player" % [_ind_min, _ind_max, _ind_bad])
				_pre_switch = _human
				# The SWITCH button emits this signal and the match connects it to
				# its own selection cycle, so this is the real control path rather
				# than a back door into the match internals.
				_touch.switch_pressed.emit()
				_go(P_SWITCH)
		P_SWITCH:
			if _t >= 0.4:
				var now := _current_human()
				_emit("[INPUT] RESULT switch_changed=%s before=%s after=%s - want true, SWITCH must hand control to another Blue player" % [
					str(now != null and now != _pre_switch),
					String(_pre_switch.name) if _pre_switch != null else "none",
					String(now.name) if now != null else "none",
				])
				_refresh_human()
				_begin_acquire(P_PASS)
		P_ACQUIRE:
			_drive_to_ball(delta)
			if _human_has_ball() or _acquire_clock <= 0.0:
				_js(0.0, 0.0, false)
				_begin_strike(_acquire_next)
		P_PASS:
			# PASS fires on press, so one clean frame of press is the whole input.
			# Tracking runs from the press so the launch itself is inside the window.
			_track_strike(delta)
			if _t >= 0.12:
				_touch.pass_down = false
			if _t >= STRIKE_WINDOW:
				_report_strike("PASS")
				_touch.pass_down = false
				_begin_acquire(P_SHOOT_AIM)
		P_PASS_WAIT:
			pass
		P_SHOOT_AIM:
			# Face the target goal with the stick first, exactly as a thumb would,
			# so the shot follows the player's real orientation.
			_aim_at_goal()
			if _t >= 0.30:
				_touch.shoot_down = true
				_go(P_SHOOT)
		P_SHOOT:
			_aim_at_goal()
			if _t >= 0.30 + 0.35:
				# Hold-to-charge then release: the release frame is the shot.
				_touch.shoot_down = false
				_begin_strike(P_SHOOT_WAIT)
		P_SHOOT_WAIT:
			_track_strike(delta)
			if _t >= STRIKE_WINDOW:
				_report_strike("SHOOT")
				_js(0.0, 0.0, false)
				_finish()


func _go(phase: int) -> void:
	_phase = phase
	_t = 0.0


func _begin_acquire(next_phase: int) -> void:
	_acquire_next = next_phase
	_acquire_clock = 5.0
	_go(P_ACQUIRE)


var _acquire_next: int = 0


func _begin_strike(next_phase: int) -> void:
	_peak_speed = 0.0
	_strike_start = _ball.global_position
	var owner = _ball.get("ball_owner")
	_own_at_strike = String(owner.name) if owner != null else "none"
	_js(0.0, 0.0, false)
	if next_phase == P_PASS:
		_touch.pass_down = true
	_go(next_phase)


## Chase the ball with the stick. Stops on its own the moment possession lands,
## and gives up after the clock so a contested ball cannot hang the run.
func _drive_to_ball(delta: float) -> void:
	_acquire_clock -= delta
	if _ball == null or _human == null:
		return
	var to_ball: Vector3 = _ball.global_position - _human.global_position
	to_ball.y = 0.0
	if to_ball.length() < 1.0:
		_js(0.0, 0.0, false)
		return
	_stick_toward(_ball.global_position)


func _stick_toward(target: Vector3) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		_js(0.0, -1.0, true)
		return
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3(0.0, 0.0, -1.0)
	else:
		fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var d: Vector3 = target - _human.global_position
	d.y = 0.0
	if d.length_squared() < 0.0001:
		_js(0.0, 0.0, false)
		return
	d = d.normalized()
	# Exact inverse of the footballer's _input_to_world mapping.
	_js(d.dot(right), -d.dot(fwd), true)


func _aim_at_goal() -> void:
	var goal_z: float = -15.5 if _human.team_id == 0 else 15.5
	_stick_toward(Vector3(0.0, _human.global_position.y, goal_z))


func _track_strike(delta: float) -> void:
	_peak_speed = maxf(_peak_speed, _flat_speed_of(_ball.linear_velocity))


func _report_strike(which: String) -> void:
	var travel: float = _flat(_ball.global_position, _strike_start)
	var bar_speed: float = 5.0 if which == "PASS" else 7.0
	var bar_travel: float = 2.0
	_emit("[INPUT] RESULT %s peak_speed=%.2f m/s travel=%.2f m in %.2f s owner_at_strike=%s - want peak > %.2f and travel > %.2f, %s must strike the ball" % [
		which, _peak_speed, travel, STRIKE_WINDOW, _own_at_strike, bar_speed, bar_travel, which,
	])


func _count_indicators() -> void:
	var visible_count: int = 0
	for f in get_tree().get_nodes_in_group("footballers"):
		if not is_instance_valid(f):
			continue
		var ind := f.get_node_or_null("Visual/Indicator")
		if ind == null:
			continue
		var is_controlled: bool = bool(f.human_controlled)
		if bool(ind.visible) == is_controlled:
			if is_controlled:
				visible_count += 1
		else:
			_ind_bad += 1
	_ind_min = mini(_ind_min, visible_count)
	_ind_max = maxi(_ind_max, visible_count)


func _current_human() -> Node3D:
	for f in get_tree().get_nodes_in_group("footballers"):
		if is_instance_valid(f) and bool(f.human_controlled):
			return f
	return null


func _human_has_ball() -> bool:
	if _ball == null or _human == null:
		return false
	if _ball.get("ball_owner") == _human:
		return true
	# A loose ball within the possession radius is also strikeable, so count it.
	if _ball.get("ball_owner") != null:
		return false
	return _flat(_ball.global_position, _human.global_position) <= 1.1


func _js(x: float, y: float, active: bool) -> void:
	if _touch == null:
		return
	_touch.stick_active = active
	_touch.move_vector = Vector2(x, y)


func _finish() -> void:
	_lines.append("[INPUT] DONE")
	print("[INPUT] DONE")
	_phase = P_DONE


func _flat_speed_of(v: Vector3) -> float:
	return sqrt(v.x * v.x + v.z * v.z)


func _flat(a: Vector3, b: Vector3) -> float:
	var dx: float = b.x - a.x
	var dz: float = b.z - a.z
	return sqrt(dx * dx + dz * dz)
