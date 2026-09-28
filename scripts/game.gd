extends Node3D
## Match flow for the small-sided football match: two goals, two teams, kickoff,
## a 90 second countdown, the scoreboard and full-time/restart.

const BLUE := 0
const RED := 1
## Nobody owns the ball: a loose ball is contested by both teams.
const NO_OWNER := -1
## The playable area the ball must stay inside. It matches the invisible pitch
## walls and sits just inside the ball's own hard clamp, so a ball that crosses
## the line is a touch out of play instead of a ball that drifts away.
const BALL_OUT_X: float = 12.9
const BALL_OUT_Z: float = 18.6

@export var ball_path: NodePath = NodePath("Ball")
## The goal BLUE defends (a ball in here scores for RED).
@export var blue_goal_area_path: NodePath = NodePath("Pitch/GoalSouth/GoalArea")
## The goal RED defends (a ball in here scores for BLUE).
@export var red_goal_area_path: NodePath = NodePath("Pitch/GoalNorth/GoalArea")
@export var hud_score_path: NodePath = NodePath("HUD/ScoreLabel")
@export var hud_timer_path: NodePath = NodePath("HUD/TimerLabel")
@export var hud_message_path: NodePath = NodePath("HUD/MessageLabel")
@export var touch_controls_path: NodePath = NodePath("HUD/TouchControls")
## The match camera. It is re-pointed at whichever Blue player the human drives.
@export var camera_path: NodePath = NodePath("Camera3D")
@export var match_time: float = 90.0
@export var kickoff_pause: float = 1.1
@export var restart_guard: float = 0.8
## Temporary boot report of the real runtime tuning each footballer ends up with.
@export var debug_dump: bool = false

var blue_score: int = 0
var red_score: int = 0
var match_over: bool = false
var time_left: float = 0.0

var _ball
## True once a crossing has already been seen, so one ball out of play triggers
## exactly one restart.
var _ball_out: bool = false
var _footballers: Array = []
var _touch
var _camera: Node
var _score_label: Label
var _timer_label: Label
var _message_label: Label
var _message_time: float = 0.0
## Last text written to the timer Label, so it is only touched when it changes.
var _timer_text: String = ""
var _goal_lock: bool = true
var _kickoff_timer: float = 0.0
var _restart_guard: float = 0.0
var _prev_shoot: bool = false
var _team: Array = []
var _selected_index: int = 0
## Seconds until another automatic change of control is allowed. This is the
## cooldown that stops the control triangle flickering between two players.
var _switch_clock: float = 0.0
## Mirror of the ball's possession book, refreshed every frame (PHASE 12). The
## BALL is the single authority (`ball_owner` / `possession_team` on the ball
## node); the match script only reads it so the rest of the game can ask the
## same question without guessing.
var possession_team: int = NO_OWNER
var attacking_team: int = NO_OWNER
var defending_team: int = NO_OWNER


func _ready() -> void:
	_ball = get_node_or_null(ball_path)
	_touch = get_node_or_null(touch_controls_path)
	_camera = get_node_or_null(camera_path)
	_score_label = get_node_or_null(hud_score_path) as Label
	_timer_label = get_node_or_null(hud_timer_path) as Label
	_message_label = get_node_or_null(hud_message_path) as Label

	_footballers = get_tree().get_nodes_in_group("footballers")
	_normalize_teams()
	_dump_tuning()

	_connect_goal(blue_goal_area_path, RED)
	_connect_goal(red_goal_area_path, BLUE)

	_collect_team()
	_adopt_authored_selection()
	_apply_selection(_selected_index)

	time_left = match_time
	_update_score_label()
	_update_timer_label()
	_start_kickoff("KICK OFF!")
	_start_selftest()


func _process(delta: float) -> void:
	_mirror_possession()
	_check_ball_out()
	# Control follows the play by itself. There is no SWITCH input any more.
	_update_auto_selection(delta)

	if _message_time > 0.0:
		_message_time -= delta
		if _message_time <= 0.0 and _message_label != null:
			_message_label.text = ""

	if _kickoff_timer > 0.0:
		_kickoff_timer -= delta
		if _kickoff_timer <= 0.0:
			_begin_play()
		return

	if match_over:
		_restart_guard = maxf(_restart_guard - delta, 0.0)
		if _shoot_edge() and _restart_guard <= 0.0:
			_restart_match()
		return

	time_left = maxf(time_left - delta, 0.0)
	_update_timer_label()
	if time_left <= 0.0:
		_end_match()


# ----------------------------------------------------------------------------
# Player selection
# ----------------------------------------------------------------------------

## Every Blue outfielder, in a stable order. Only these can ever be controlled.
func _collect_team() -> void:
	_team.clear()
	for footballer in _footballers:
		if footballer == null or not is_instance_valid(footballer):
			continue
		if footballer.team_id == BLUE and footballer.role != "goalkeeper":
			_team.append(footballer)
	_team.sort_custom(func(a, b): return String(a.name) < String(b.name))


## Start on whichever Blue player the scene already marked as controlled.
func _adopt_authored_selection() -> void:
	_selected_index = 0
	for i in range(_team.size()):
		if _team[i].human_controlled:
			_selected_index = i
			return


## Hand control to exactly one Blue player and let the footballer show the
## triangle indicator. Nothing else in the project grants control, so the AI can
## never take over the player the human is driving.
func _apply_selection(index: int) -> void:
	if _team.is_empty():
		return
	_selected_index = wrapi(index, 0, _team.size())
	for i in range(_team.size()):
		var footballer = _team[i]
		if footballer.has_method("set_human_controlled"):
			footballer.call("set_human_controlled", i == _selected_index)
	# Point the camera at whoever is actually being driven, so a SWITCH never
	# leaves the action half off the screen.
	if _camera != null and _camera.has_method("set_player"):
		_camera.call("set_player", _team[_selected_index])


func _selected_player():
	if _team.is_empty():
		return null
	return _team[_selected_index]


## --- Automatic control -------------------------------------------------------
## There is no SWITCH button and no SWITCH key any more. Control is handed to the
## Blue player best placed to affect the play, decided from where the ball is
## GOING rather than only where it is, which third of the pitch that is, and who
## has possession. It is deliberately slow to change: a margin, a cooldown and a
## lock while the driven player is involved, so the triangle never flickers.
##
## How far ahead a moving ball is led, as a fraction of its own speed, capped in
## seconds so a very fast shot cannot be led off the pitch.
const LEAD_TIME: float = 0.06
const LEAD_MAX: float = 0.75
## Another Blue player must score this many metres better before control moves.
const SWITCH_MARGIN: float = 2.2
## Minimum seconds between two automatic changes of control.
const SWITCH_COOLDOWN: float = 0.55
## Control is kept while the driven player is this close to the ball: receiving,
## dribbling, or lining up a pass or a shot.
const KEEP_RADIUS: float = 3.6
## ...and while closing down an opponent who has the ball, out to this range.
const PRESS_RADIUS: float = 5.0
## Beyond this distance from the halfway line the ball counts as being in a
## defensive or attacking third rather than in midfield.
const THIRD_Z: float = 6.0
## Span used to turn a player's natural depth into an attacking bias.
const DEPTH_SPAN: float = 10.0


## Reconsider who the human drives. Called every frame, but it only ever changes
## anything when another Blue player is CLEARLY the right one, so the controlled
## player is stable instead of switching constantly.
func _update_auto_selection(delta: float) -> void:
	if _team.size() <= 1 or _ball == null or not is_instance_valid(_ball):
		return
	# Play is frozen for a kickoff, a goal or full time: leave control where it is
	# so a restart is never accompanied by a sudden change of player.
	if _goal_lock or _kickoff_timer > 0.0 or match_over:
		_switch_clock = 0.0
		return
	_switch_clock = maxf(_switch_clock - delta, 0.0)

	var point := _ball_future_point()
	var owner = _ball.get("ball_owner")
	var owner_valid: bool = owner != null and is_instance_valid(owner)
	var they_have_it: bool = owner_valid and int(owner.team_id) != BLUE

	var best_index := _selected_index
	var best_score := 1.0e9
	for i in range(_team.size()):
		var score := _selection_score(i, point, they_have_it)
		if score < best_score:
			best_score = score
			best_index = i

	if best_index == _selected_index:
		return
	if _switch_clock > 0.0 or _control_is_locked():
		return
	var current_score := _selection_score(_selected_index, point, they_have_it)
	# Only move when the alternative is CLEARLY better. Without this margin two
	# players at similar range would trade control back and forth every frame.
	if best_score >= current_score - SWITCH_MARGIN:
		return
	_apply_selection(best_index)
	_switch_clock = SWITCH_COOLDOWN


## Where the ball is heading. A moving ball is led by its own travel time, so a
## fast pass is judged by its predicted destination.
func _ball_future_point() -> Vector3:
	var position: Vector3 = _ball.global_position
	var velocity: Vector3 = _ball.linear_velocity
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var lead: float = clampf(flat.length() * LEAD_TIME, 0.0, LEAD_MAX)
	return position + flat * lead


## How good a choice a Blue player is right now. LOWER IS BETTER: the distance
## they must cover to reach the ball's future point, reduced by a bonus for being
## the right kind of player for the area of the pitch the ball is in.
func _selection_score(index: int, point: Vector3, they_have_it: bool) -> float:
	var footballer = _team[index]
	if footballer == null or not is_instance_valid(footballer):
		return 1.0e9
	var distance := _flat_distance(footballer.global_position, point)
	# `home_position.z` is how deep this player's own slot is. Bigger z is deeper,
	# because Blue defends the +z goal and attacks the -z goal.
	var depth: float = footballer.home_position.z
	var bonus := 0.0
	if point.z > THIRD_Z:
		# Our defensive third: a deeper player is the right one to control.
		bonus = depth * 0.25
	elif point.z < -THIRD_Z:
		# Our attacking third: the most advanced player.
		bonus = maxf(0.0, DEPTH_SPAN - depth) * 0.25
	if they_have_it:
		# Red has it, so the useful player is whoever defends it best, which
		# favours the deeper slots.
		bonus += depth * 0.15
	return distance - bonus


## True while control must NOT move, because the driven player is part of the
## play: receiving the ball, dribbling it, or challenging for it.
func _control_is_locked() -> bool:
	var current = _selected_player()
	if current == null or not is_instance_valid(current):
		return false
	var owner = _ball.get("ball_owner")
	if owner != null and is_instance_valid(owner) and owner == current:
		# Carrying the ball: dribbling, or lining up a pass or a shot.
		return true
	var distance := _flat_distance(current.global_position, _ball.global_position)
	if distance <= KEEP_RADIUS:
		# Close to the ball: about to win it, or already challenging for it.
		return true
	if owner != null and is_instance_valid(owner) and int(owner.team_id) != BLUE:
		return distance <= PRESS_RADIUS
	return false


## Kept only so the disabled self-test harness still has an entry point. It no
## longer grants manual control: it just forces one reassessment.
func _cycle_selection() -> void:
	_switch_clock = 0.0
	_update_auto_selection(SWITCH_COOLDOWN)


func _flat_distance(from: Vector3, to: Vector3) -> float:
	var dx := to.x - from.x
	var dz := to.z - from.z
	return sqrt(dx * dx + dz * dz)


# ----------------------------------------------------------------------------
# Kickoff, goals and full time
# ----------------------------------------------------------------------------

func _connect_goal(path: NodePath, scoring_team: int) -> void:
	var area := get_node_or_null(path) as Area3D
	if area == null:
		push_warning("Goal area not found: %s" % str(path))
		return
	area.body_entered.connect(_on_goal_scored.bind(scoring_team))


func _on_goal_scored(body: Node3D, scoring_team: int) -> void:
	if match_over or _goal_lock or not body.is_in_group("ball"):
		return
	if scoring_team == BLUE:
		blue_score += 1
	else:
		red_score += 1
	_update_score_label()
	var who := "BLUE" if scoring_team == BLUE else "RED"
	_start_kickoff("GOAL!  %s SCORE" % who)


## A ball that has crossed the playable boundary is a touch out of play: the match
## restarts the same way a kickoff does, so the ball can never drift off and
## vanish. Ignored during a kickoff, a goal celebration or full time, and guarded
## so one crossing starts exactly one restart.
func _check_ball_out() -> void:
	if _ball == null or not is_instance_valid(_ball):
		return
	if _goal_lock or _kickoff_timer > 0.0 or match_over:
		return
	var position: Vector3 = _ball.global_position
	if absf(position.x) > BALL_OUT_X or absf(position.z) > BALL_OUT_Z:
		if _ball_out:
			return
		_ball_out = true
		_start_kickoff("OUT OF PLAY")
		return
	_ball_out = false


func _start_kickoff(message: String) -> void:
	_goal_lock = true
	_set_play_enabled(false)
	_reset_positions()
	_kickoff_timer = kickoff_pause
	_set_message(message, 1.5)


func _begin_play() -> void:
	if match_over:
		return
	_goal_lock = false
	_set_play_enabled(true)


func _end_match() -> void:
	match_over = true
	_restart_guard = restart_guard
	_set_play_enabled(false)
	var result := "DRAW"
	if blue_score > red_score:
		result = "BLUE WIN"
	elif red_score > blue_score:
		result = "RED WIN"
	_set_message("FULL TIME\n%s\n%d - %d\nTAP SHOOT TO PLAY AGAIN" % [result, blue_score, red_score], 9999.0)


func _restart_match() -> void:
	match_over = false
	blue_score = 0
	red_score = 0
	time_left = match_time
	_update_score_label()
	_update_timer_label()
	_start_kickoff("KICK OFF!")


func _shoot_edge() -> bool:
	var held := Input.is_action_pressed("shoot")
	if _touch != null and _touch.shoot_down:
		held = true
	var edge := held and not _prev_shoot
	_prev_shoot = held
	return edge


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

## Keep the match-level possession mirror in step with the ball. The ball node is
## the only writer of possession; this just republishes it so AI and HUD code can
## read one consistent match state.
func _mirror_possession() -> void:
	if _ball == null or not is_instance_valid(_ball):
		possession_team = NO_OWNER
		attacking_team = NO_OWNER
		defending_team = NO_OWNER
		return
	var team: int = int(_ball.get("possession_team"))
	possession_team = team
	if team == NO_OWNER:
		attacking_team = NO_OWNER
		defending_team = NO_OWNER
		return
	attacking_team = team
	defending_team = RED if team == BLUE else BLUE


## The scene marks each team by the node it is parented under, and its stale
## serialized overrides can leave team_id at its default. The match script is the
## single authority for teams, so it stamps every footballer from the group the
## scene placed it in.
func _normalize_teams() -> void:
	for footballer in _footballers:
		if footballer == null or not is_instance_valid(footballer):
			continue
		var parent = footballer.get_parent()
		if parent == null:
			continue
		if parent.name == "TeamRed":
			footballer.team_id = RED
		elif parent.name == "TeamBlue":
			footballer.team_id = BLUE


## Boot report of the real tuning each footballer ends up with, so stale values
## carried by the scene file are visible instead of guessed at.
## Behavioural validation harness. It is NOT part of the game: it drives the
## touch controls by itself and teleports the ball to the human's feet, which is
## exactly the "ball follows / teleports to a player" behaviour the ball system
## must never show. The ball is the one authority for the ball, so both probes
## stay off in normal play and are only ever turned on for a deliberate test run.
const SELFTEST: bool = false
const SELFTEST_SCRIPT: String = "res://scripts/match_selftest.gd"
## Read-only shape observer. Samples the match without touching input; off for
## normal play, turned on only while validating team shape and spacing.
const SHAPE_PROBE: bool = false
## Behavioural input probe. Drives the on-screen stick and the PASS / SHOOT /
## SWITCH buttons exactly as a thumb would, and never teleports the ball or writes
## a footballer. Off in normal play, on only while validating the controls.
const INPUT_PROBE: bool = false
const INPUT_PROBE_SCRIPT: String = "res://scripts/input_probe.gd"


func _start_selftest() -> void:
	if SHAPE_PROBE:
		var observer_script: GDScript = load("res://scripts/shape_probe.gd") as GDScript
		if observer_script != null:
			var observer: Node = observer_script.new()
			observer.name = "ShapeProbe"
			add_child(observer)
			observer.call("begin", self)
	if INPUT_PROBE:
		var input_script: GDScript = load(INPUT_PROBE_SCRIPT) as GDScript
		if input_script != null:
			var input_probe: Node = input_script.new()
			input_probe.name = "InputProbe"
			add_child(input_probe)
			input_probe.call("begin", self)
	if not SELFTEST:
		return
	var script: GDScript = load(SELFTEST_SCRIPT) as GDScript
	if script == null:
		print("[AUTOTEST] ABORT self-test script missing")
		return
	var probe: Node = script.new()
	probe.name = "MatchSelfTest"
	add_child(probe)


func _dump_tuning() -> void:
	if not debug_dump:
		return
	for footballer in _footballers:
		if footballer == null or not is_instance_valid(footballer):
			continue
		print("[SE-DUMP] %s team=%s role=%s human=%s walk=%.2f sprint=%.2f accel=%.2f possess=%.2f cam=%s touch=%s" % [
			String(footballer.name), str(footballer.team_id), str(footballer.role),
			str(footballer.human_controlled), footballer.walk_speed, footballer.sprint_speed,
			footballer.acceleration, footballer.possess_radius,
			str(footballer.camera_path), str(footballer.touch_controls_path),
		])


func _set_play_enabled(value: bool) -> void:
	for footballer in _footballers:
		if footballer != null and footballer.has_method("set_play_enabled"):
			footballer.call("set_play_enabled", value)


func _reset_positions() -> void:
	if _ball != null and _ball.has_method("reset_to_spawn"):
		_ball.call("reset_to_spawn")
	for footballer in _footballers:
		if footballer != null and footballer.has_method("reset_to_home"):
			footballer.call("reset_to_home")


func _update_score_label() -> void:
	if _score_label != null:
		_score_label.text = "BLUE %d - %d RED" % [blue_score, red_score]


func _update_timer_label() -> void:
	if _timer_label == null:
		return
	# Count down on whole seconds and zero-pad the minutes, so the clock reads
	# 01:30, 01:29, 01:28 ... and never sits on a stale value.
	var seconds := maxi(int(ceil(time_left)), 0)
	var text := "%02d:%02d" % [seconds / 60, seconds % 60]
	# Mobile: only touch the Label when the visible text actually changes.
	if text != _timer_text:
		_timer_text = text
		_timer_label.text = text


func _set_message(text: String, seconds: float) -> void:
	if _message_label == null:
		return
	_message_label.text = text
	_message_time = seconds
