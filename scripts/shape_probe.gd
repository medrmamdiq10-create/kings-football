extends Node
## Read-only match observer (validation only).
##
## It NEVER touches input, the ball, or any footballer: it only samples positions
## and prints what the match actually did. Used to check team shape, spacing,
## keeper activity and the clock without puppeting the player being tested.

const SAMPLE_TIME: float = 9.0

var _match: Node = null
var _ball: Node3D = null
var _t: float = 0.0
var _frames: int = 0

## Worst (smallest) distance ever seen between any two footballers = stacking.
var _min_pair: float = 9999.0
var _min_pair_who: String = ""
## Most players ever crammed within 2.5 m of the ball = everyone chasing.
var _max_near_ball: int = 0
## Widest spread of the blue outfielders across x = holding width.
var _max_spread_x: float = 0.0
## Total distance the two keepers travelled = is the keeper actually alive.
var _keeper_travel: float = 0.0
var _keeper_last: Dictionary = {}
## Distinct timer readings seen = is the clock counting down.
var _timer_readings: Dictionary = {}
## Camera distance from the action.
var _cam_min: float = 9999.0
var _cam_max: float = 0.0
## Spinning: total visual yaw a player accrued while it was barely moving. A
## footballer standing still must not rotate, so this must stay near zero.
var _spin_still: float = 0.0
var _last_yaw: Dictionary = {}
## Per-player accumulation, so one pirouetting body cannot hide inside the sum.
var _spin_still_by_player: Dictionary = {}
## Loose-ball control: how close anybody ever got to a ball nobody owned, which
## is what proves a chaser actually reaches the ball and takes it.
var _loose_min: float = 9999.0
var _possess_changes: int = 0
var _last_owner = null
var _owners: Dictionary = {}
## Ball ceilings: nothing may fly forever or speed out of control.
var _ball_max_y: float = 0.0
var _ball_max_speed: float = 0.0

var _done: bool = false


func begin(match_node: Node) -> void:
	_match = match_node
	_ball = get_tree().get_first_node_in_group("ball")
	for f in get_tree().get_nodes_in_group("footballers"):
		if f.role == "goalkeeper":
			_keeper_last[f] = f.global_position


func _physics_process(delta: float) -> void:
	if _done or _match == null:
		return
	_t += delta
	_frames += 1
	_sample()
	if _t >= SAMPLE_TIME:
		_done = true
		_report()


func _sample() -> void:
	var players: Array = get_tree().get_nodes_in_group("footballers")

	# Stacking: closest pair of bodies anywhere on the pitch.
	for i in range(players.size()):
		for j in range(i + 1, players.size()):
			var a = players[i]
			var b = players[j]
			if not is_instance_valid(a) or not is_instance_valid(b):
				continue
			var d: float = _flat(a.global_position, b.global_position)
			if d < _min_pair:
				_min_pair = d
				_min_pair_who = "%s/%s" % [String(a.name), String(b.name)]

	# All-chase: how many bodies sit right on top of the ball.
	if _ball != null and is_instance_valid(_ball):
		var near := 0
		for p in players:
			if _flat(p.global_position, _ball.global_position) < 2.5:
				near += 1
		_max_near_ball = maxi(_max_near_ball, near)

	# Width: spread of the blue outfielders across x.
	var xs: Array = []
	for p in players:
		if p.team_id == 0 and p.role != "goalkeeper":
			xs.append(p.global_position.x)
	if xs.size() >= 2:
		_max_spread_x = maxf(_max_spread_x, xs.max() - xs.min())

	# Keeper activity.
	for k in _keeper_last.keys():
		if not is_instance_valid(k):
			continue
		var here: Vector3 = k.global_position
		_keeper_travel += _flat(here, _keeper_last[k])
		_keeper_last[k] = here

	# Spinning while standing: the visual yaw is what the player actually sees, so
	# that is what gets measured, and only while the body is barely moving.
	for p in players:
		if not is_instance_valid(p):
			continue
		var visual := p.get_node_or_null("Visual") as Node3D
		if visual == null:
			continue
		var yaw: float = visual.rotation.y
		var player_velocity: Vector3 = p.velocity
		if _last_yaw.has(p) and _flat_speed_of(player_velocity) < 1.0:
			var step := absf(angle_difference(_last_yaw[p], yaw))
			_spin_still += step
			_spin_still_by_player[p] = float(_spin_still_by_player.get(p, 0.0)) + step
		_last_yaw[p] = yaw

	# Loose-ball control: how close the nearest player got while the ball was
	# genuinely free, and who ended up owning it.
	if _ball != null and is_instance_valid(_ball):
		_ball_max_y = maxf(_ball_max_y, _ball.global_position.y)
		var ball_velocity: Vector3 = _ball.linear_velocity
		_ball_max_speed = maxf(_ball_max_speed, _flat_speed_of(ball_velocity))
		var owner = _ball.get("ball_owner")
		if owner == null:
			_loose_min = minf(_loose_min, _nearest_player_distance(_ball.global_position))
		if owner != _last_owner:
			if _last_owner != null or owner != null:
				_possess_changes += 1
			if owner != null:
				_owners[String(owner.name)] = true
			_last_owner = owner

	# Clock.
	if _match.get("_timer_label") != null:
		_timer_readings[str(_match.get("_timer_label").text)] = true

	# Camera framing.
	var cam := get_viewport().get_camera_3d()
	if cam != null and _ball != null:
		var d: float = cam.global_position.distance_to(_ball.global_position)
		_cam_min = minf(_cam_min, d)
		_cam_max = maxf(_cam_max, d)


func _report() -> void:
	print("[SHAPE] RESULT min_pair_distance=%.2f m (%s) - want > 0.70, players must not stack" % [_min_pair, _min_pair_who])
	print("[SHAPE] RESULT max_players_within_2.5m_of_ball=%d - want <= 4, NOT all ten chasing" % _max_near_ball)
	print("[SHAPE] RESULT blue_outfield_width=%.2f m - want > 8.00, side must hold width" % _max_spread_x)
	print("[SHAPE] RESULT keeper_travel=%.2f m over %.1f s - want > 0.50, keeper must be active" % [_keeper_travel, SAMPLE_TIME])
	print("[SHAPE] RESULT distinct_timer_readings=%d - want >= 7 over %.1f s, clock must tick" % [_timer_readings.size(), SAMPLE_TIME])
	print("[SHAPE] RESULT timer_text=%s" % str(_timer_readings.keys()))
	print("[SHAPE] RESULT camera_ball_distance=%.1f..%.1f m - want a stable 18..34 band, action framed" % [_cam_min, _cam_max])
	var spin_max: float = 0.0
	var spin_who: String = ""
	for p in _spin_still_by_player.keys():
		var v: float = _spin_still_by_player[p]
		if v > spin_max:
			spin_max = v
			spin_who = String(p.name)
	print("[SHAPE] RESULT spin_while_still=%.2f rad total, worst single player=%.2f rad (%s) - want worst < 3.14, no player may pirouette on the spot" % [_spin_still, spin_max, spin_who])
	print("[SHAPE] RESULT loose_ball_closest_approach=%.2f m - want <= 1.25, a chaser must reach the ball" % _loose_min)
	print("[SHAPE] RESULT possession_changes=%d distinct_owners=%d - want > 0 and > 1, ball genuinely contested" % [_possess_changes, _owners.size()])
	print("[SHAPE] RESULT ball_max_height=%.2f m ball_max_speed=%.2f m/s - want < 4.00 and <= 26.00, never flies or runs away" % [_ball_max_y, _ball_max_speed])
	print("[SHAPE] SAMPLES=%d" % _frames)


func _flat_speed_of(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


## Closest footballer to a point, in the flat plane.
func _nearest_player_distance(point: Vector3) -> float:
	var best: float = 9999.0
	for f in get_tree().get_nodes_in_group("footballers"):
		if not is_instance_valid(f):
			continue
		best = minf(best, _flat(f.global_position, point))
	return best


func _flat(a: Vector3, b: Vector3) -> float:
	var dx: float = b.x - a.x
	var dz: float = b.z - a.z
	return sqrt(dx * dx + dz * dz)
