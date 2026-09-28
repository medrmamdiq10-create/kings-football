extends CharacterBody3D
## One footballer of either team. ONE script, ONE movement authority per player:
##
##   human_controlled = true -> `_human_tick()`, driven only by the joystick.
##   role = "goalkeeper"     -> `_keeper_tick()`, its own goalkeeper controller.
##   otherwise               -> `_outfield_tick()`, the outfield state machine.
##
## The AI never runs for the controlled player and never writes another player's
## velocity, so nothing can fight the joystick. There is deliberately no jump:
## a footballer never moves upward, is clamped inside the pitch, and cannot fly.
##
## Ball ownership lives on the ball (`ball_owner`); this script only asks for it
## when it is physically close enough, and dribbling is a force on the ball, not
## a parent, not a teleport.

enum { TEAM_BLUE, TEAM_RED }

## Explicit AI states (PHASE 9). Only one is active at a time and it is readable
## as `ai_state` for debugging.
enum AIState {
	IDLE,
	SUPPORT,             ## My team has the ball: create space, offer a lane.
	ATTACK,              ## My team has the ball and I am the one making the run.
	DEFEND,              ## Their team has the ball: hold shape, track, cover.
	PRESS,               ## Loose ball: close it down at speed.
	CHASE_BALL,          ## Loose ball, chasing the bounce.
	RECEIVE,             ## Moving onto a pass already played to me.
	DRIBBLE,             ## I have the ball and am carrying it forward.
	PASS,                ## I have the ball and am playing a pass.
	SHOOT,               ## I have the ball and am striking at goal.
	RETURN_TO_POSITION,  ## Frozen play: walk back to my home spot.
}

@export var team_id: int = TEAM_BLUE
@export var role: String = "outfield"
@export var human_controlled: bool = false

@export_group("Movement")
@export var walk_speed: float = 6.4
@export var sprint_speed: float = 9.2
@export var acceleration: float = 34.0
@export var turn_speed: float = 12.0

@export_group("Possession")
## How close the ball must be to be taken. Small on purpose: no long-range pull.
@export var possess_radius: float = 1.25
## How far the ball may drift before it counts as lost. A soft, push-not-glue
## carry means the ball lags a little behind a sprint, so this leaves just enough
## room for that lag without the ball ever being dragged around.
@export var lose_radius: float = 2.2
## A rival must be this much closer to the ball before it changes hands, so two
## players on the same spot do not flicker ownership every frame.
@export var steal_margin: float = 0.3
## Where the ball sits ahead of the feet while walking and while sprinting, so a
## faster run produces a noticeably larger touch.
@export var carry_distance: float = 0.70
@export var carry_distance_fast: float = 1.8
## How long a footballer is barred from re-taking the ball after kicking it, so
## the ball actually leaves the foot instead of being grabbed straight back.
@export var release_lock: float = 0.3

@export_group("Passing and shooting")
@export var pass_speed: float = 13.0
## A pass carries only a trace of lift, so normal passes stay on the deck.
@export var pass_lift: float = 0.0
@export var pass_range: float = 20.0
@export var pass_hold_time: float = 0.42
@export var min_shot_power: float = 11.0
@export var max_shot_power: float = 21.0
@export var charge_time: float = 0.8
## A shot's vertical speed, and its hard cap. Both are small, so however hard the
## ball is struck it cannot balloon into the sky.
@export var shot_min_lift: float = 0.5
@export var shot_max_lift: float = 2.4
@export var shot_hold_time: float = 0.5

@export_group("AI")
@export var ai_shot_power: float = 17.0
@export var ai_shot_lift: float = 1.5
@export var ai_shoot_range: float = 13.0
## How far an attacker pushes up the pitch from their home spot while the side
## has the ball.
@export var attack_push: float = 7.0
## How far a supporting team-mate pushes up the pitch from their home spot.
@export var support_push: float = 5.0
## How strongly a support player drifts toward the ball's lane, and how strongly
## a defender tracks the ball across the pitch. Both are small so the side keeps
## its shape instead of collapsing onto the ball.
@export var support_follow: float = 0.30
@export var defend_follow: float = 0.40
## How far the defensive block drops back from its home line when the other side
## has the ball.
@export var defend_drop: float = 2.5
## How far the whole block slides sideways per metre of ball offset from the
## centre line. Keeps the shape shifting as a unit instead of collapsing.
@export var block_slide: float = 0.30
@export var keeper_clear_power: float = 15.0
@export var keeper_clear_lift: float = 2.2

@export_group("Scene")
@export var camera_path: NodePath = NodePath("../../Camera3D")
@export var touch_controls_path: NodePath = NodePath("../../HUD/TouchControls")

const BLUE_JERSEY := Color(0.13, 0.42, 0.92, 1.0)
const BLUE_SHORTS := Color(0.94, 0.95, 0.98, 1.0)
const BLUE_KEEPER := Color(0.42, 0.93, 0.24, 1.0)
const RED_JERSEY := Color(0.88, 0.18, 0.16, 1.0)
const RED_SHORTS := Color(0.12, 0.12, 0.15, 1.0)
const RED_KEEPER := Color(0.98, 0.80, 0.15, 1.0)
const SKIN := Color(0.83, 0.64, 0.48, 1.0)
const HAIR := Color(0.15, 0.11, 0.09, 1.0)
const SOCK := Color(0.93, 0.93, 0.95, 1.0)

## Pitch limits. The walls sit at x = +-12.2 and z = +-18.2; players are clamped
## inside them so nobody can leave the field or slip through a corner.
const LIMIT_X: float = 11.6
const LIMIT_Z: float = 17.6
## Bodies closer than this steer apart, so team-mates spread instead of stacking.
const SEPARATION_RADIUS: float = 1.35
## Below this the two bodies genuinely overlap: the inward part of the velocity is
## removed so a jam resolves, but no force is ever added, so nothing can explode.
const CONTACT_RADIUS: float = 0.85

## --- Football movement tuning -------------------------------------------------
## A player stands still inside this radius of its target instead of milling
## around it, and slows down over the last `ARRIVE_RADIUS` metres. This is what
## stops a body orbiting a point it could never quite reach.
const ARRIVE_DEADZONE: float = 0.35
const ARRIVE_RADIUS: float = 2.0
## Hard cap on the separation nudge, in metres of target offset. Two team-mates
## used to displace each other's target by nearly two metres on every frame, which
## made ten players drift with no football reason; the nudge is a nudge now.
const SEPARATION_MAX: float = 0.6
## How much closer a team-mate must be to the ball before it takes the ball job
## off the player who currently holds it. Without this margin the job flickered
## between two almost-equally-close players every frame, and they took turns
## sprinting to two different places.
const DUTY_MARGIN: float = 0.75
## Below this speed a player is standing, not running: the body holds its last
## heading instead of being spun by leftover velocity noise.
const FACING_MIN_SPEED: float = 0.9
## Ignore heading errors this small. A target that wobbles by a hair must never
## rotate a body, or a twitching formation point spins a player on the spot.
const FACING_DEADZONE: float = 0.10
## Fastest a footballer's body may pivot, in radians per second.
const TURN_RATE: float = 7.0

## Temporary instrumentation: prints the exact impulse of every kick so the
## validation harness can prove the ball actually leaves the foot. Off in normal
## play - both of these only exist for a deliberate test run.
const DEBUG_HUMAN: bool = false
const DEBUG_KICK: bool = false

static var _material_cache: Dictionary = {}

var charge: float = 0.0
var can_play: bool = true
var home_position: Vector3 = Vector3.ZERO
## Current AI state (AIState). Read-only outside this script; used for debug.
var ai_state: int = AIState.IDLE

var _gravity: float = 9.8
var _ball: Node3D
var _touch
var _camera: Camera3D
var _visual: Node3D
var _indicator: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _owns_ball: bool = false
var _possess_lock: float = 0.0
var _ai_action_clock: float = 0.0
var _prev_shoot: bool = false
var _prev_pass: bool = false
var _run_phase: float = 0.0
## Last physics step, so visual turning can be rate limited in radians per second.
var _last_delta: float = 0.016
## Kick animation: a short forward leg swing fired the moment the ball is struck,
## so PASS and SHOOT read visibly and are synced to the actual kick, not to a
## guess. `_kick_anim_amp` separates the bigger shot swing from the pass swing.
var _kick_anim: float = 0.0
var _kick_anim_amp: float = 1.0
## How long a kick swing lasts, in seconds.
const KICK_ANIM_TIME: float = 0.3
var _facing: Vector3 = Vector3(0.0, 0.0, -1.0)
var _attack_dir: Vector3 = Vector3(0.0, 0.0, -1.0)
var _target_goal_z: float = -15.5
## Formation slot, taken from the authored home spot: which lane this player
## covers (-1 left .. +1 right) and how far up the pitch they naturally sit.
## Every AI target is built from the slot, so the side keeps a shape instead of
## collapsing onto the ball.
var _slot_lane: float = 0.0
var _slot_depth: float = 0.0


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	home_position = global_position
	_slot_lane = clampf(home_position.x / 7.0, -1.0, 1.0)
	_slot_depth = home_position.z
	_ball = get_tree().get_first_node_in_group("ball")
	_touch = get_node_or_null(touch_controls_path)
	_camera = get_node_or_null(camera_path) as Camera3D
	_visual = get_node_or_null("Visual")
	_indicator = get_node_or_null("Visual/Indicator")
	if _indicator != null:
		_indicator.visible = human_controlled
	# Sides only. Anything else carrying this script keeps a neutral direction.
	if team_id == TEAM_BLUE:
		_attack_dir = Vector3(0.0, 0.0, -1.0)
		_target_goal_z = -15.5
	elif team_id == TEAM_RED:
		_attack_dir = Vector3(0.0, 0.0, 1.0)
		_target_goal_z = 15.5
	else:
		_attack_dir = Vector3(0.0, 0.0, -1.0)
		_target_goal_z = 0.0
	_apply_slot()
	_facing = _attack_dir
	if _visual != null:
		_leg_l = _visual.get_node_or_null("LegLPivot")
		_leg_r = _visual.get_node_or_null("LegRPivot")
		_arm_l = _visual.get_node_or_null("ArmLPivot")
		_arm_r = _visual.get_node_or_null("ArmRPivot")
		_visual.rotation.y = atan2(-_facing.x, -_facing.z)
	_paint()


func _physics_process(delta: float) -> void:
	_last_delta = delta
	# Gravity, and a hard rule: a footballer never gains height.
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y = maxf(velocity.y - _gravity * delta, -25.0)
	if velocity.y > 0.0:
		velocity.y = 0.0

	if human_controlled:
		_human_tick(delta)
	else:
		_ai_tick(delta)

	move_and_slide()
	_clamp_to_pitch()
	_resolve_contact()
	_possession_tick(delta)
	_advance_run_cycle(delta)


# ----------------------------------------------------------------------------
# Match control
# ----------------------------------------------------------------------------

func set_play_enabled(value: bool) -> void:
	can_play = value
	if not value:
		charge = 0.0
		_prev_shoot = false
		_prev_pass = false


## Hand control of this footballer to the human, or give it back to the AI. Only
## the match script ever calls this, so the AI can never take over the player the
## human is driving. The ground triangle marks whoever is controlled.
func set_human_controlled(value: bool) -> void:
	human_controlled = value
	if _indicator != null:
		_indicator.visible = value
	charge = 0.0
	_prev_shoot = false
	_prev_pass = false
	_ai_action_clock = 0.0
	if value:
		# Kill any AI momentum so the joystick responds from the first frame.
		velocity.x = 0.0
		velocity.z = 0.0
		_facing = _attack_dir
		_apply_facing(1.0)


func reset_to_home() -> void:
	global_position = home_position
	velocity = Vector3.ZERO
	charge = 0.0
	_prev_shoot = false
	_prev_pass = false
	_ai_action_clock = 0.0
	_possess_lock = 0.0
	ai_state = AIState.IDLE
	_facing = _attack_dir
	if _visual != null:
		_visual.rotation.y = atan2(-_facing.x, -_facing.z)


## Called by the match script when this footballer gives up control, and when
## play freezes. Ownership is dropped without a kick.
func release_ball() -> void:
	var ball := _ball_node()
	_owns_ball = false
	if ball != null and ball.get("ball_owner") == self:
		ball.call("release")


func is_human_player() -> bool:
	return human_controlled


## 0.0 to 1.0 charge level of the current shot, for HUD feedback.
func shot_charge() -> float:
	return charge


func ai_state_name() -> String:
	return AIState.keys()[ai_state]


## One line of debug state, used by the validation probe.
func debug_line() -> String:
	var ball := _ball_node()
	var distance := -1.0
	if ball != null:
		distance = _flat_distance_to(global_position, ball.global_position)
	return "%s team=%d role=%s human=%s state=%s owns=%s ball_dist=%.2f pos=%s" % [
		String(name), team_id, role, str(human_controlled), ai_state_name(),
		str(_owns_ball), distance, str(global_position.round()),
	]


# ----------------------------------------------------------------------------
# Human control - the ONLY writer of the controlled player's velocity
# ----------------------------------------------------------------------------

func _human_tick(delta: float) -> void:
	ai_state = AIState.IDLE
	var input := _read_move_input()
	var direction := _input_to_world(input)
	var analog := clampf(input.length(), 0.0, 1.0)
	if direction.length_squared() < 0.0001:
		analog = 0.0
	if not can_play:
		analog = 0.0
		charge = 0.0
		_prev_shoot = false
		_prev_pass = false

	var target_speed := walk_speed
	if analog > 0.0 and _sprint_held():
		target_speed = sprint_speed
	var desired := direction * (target_speed * analog)
	velocity.x = move_toward(velocity.x, desired.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, desired.z, acceleration * delta)

	if direction.length_squared() > 0.0001:
		_facing = direction
	else:
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		if flat.length() > 0.4:
			_facing = flat.normalized()
	_apply_facing(clampf(turn_speed * delta, 0.0, 1.0))

	if can_play:
		_human_actions(delta)


func _read_move_input() -> Vector2:
	var keyboard := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if keyboard.length() > 0.05:
		return keyboard.limit_length(1.0)
	# Only trust the thumb-stick while it is genuinely held, so a stale vector can
	# never drive the controlled player on its own.
	if _touch != null and _touch.stick_active:
		return _touch.move_vector.limit_length(1.0)
	return Vector2.ZERO


func _sprint_held() -> bool:
	if Input.is_action_pressed("sprint"):
		return true
	if _touch != null and _touch.sprint_active:
		return true
	return false


## SHOOT is hold-to-charge and fires on release; PASS fires on press. Both only
## do something when this player actually owns the ball (PHASE 7 and 8).
func _human_actions(delta: float) -> void:
	var shoot_held := Input.is_action_pressed("shoot")
	var pass_held := Input.is_action_pressed("pass")
	if _touch != null:
		if _touch.shoot_down:
			shoot_held = true
		if _touch.pass_down:
			pass_held = true

	if shoot_held:
		charge = minf(charge + delta / charge_time, 1.0)
	elif _prev_shoot:
		_human_shoot(charge)
		charge = 0.0
	_prev_shoot = shoot_held

	if pass_held and not _prev_pass:
		_human_pass()
	_prev_pass = pass_held


func _human_shoot(charge_level: float) -> void:
	var ball := _ball_node()
	if DEBUG_HUMAN:
		print("[HUMAN] SHOOT release charge=%.2f may_strike=%s owns=%s lock=%.2f dist=%.2f" % [
			charge_level, str(_may_strike_ball(ball)), str(_owns_ball), _possess_lock,
			_flat_distance_to(global_position, ball.global_position) if ball != null else -1.0,
		])
	if not _may_strike_ball(ball):
		return
	var power := lerpf(min_shot_power, max_shot_power, charge_level)
	var lift := lerpf(shot_min_lift, shot_max_lift, charge_level)
	if DEBUG_HUMAN:
		print("[HUMAN] SHOOT fired power=%.2f dir=(%.2f,%.2f,%.2f)" % [power, _shot_direction().x, _shot_direction().y, _shot_direction().z])
	_kick(ball, _shot_direction(), power, lift, true)


func _human_pass() -> void:
	var ball := _ball_node()
	if DEBUG_HUMAN:
		print("[HUMAN] PASS press may_strike=%s owns=%s lock=%.2f dist=%.2f" % [
			str(_may_strike_ball(ball)), str(_owns_ball), _possess_lock,
			_flat_distance_to(global_position, ball.global_position) if ball != null else -1.0,
		])
	if not _may_strike_ball(ball):
		return
	var mate = _best_pass_target(true)
	var direction := _flat_facing()
	if mate != null:
		direction = _pass_direction_to(mate, ball.global_position)
	_kick(ball, direction, pass_speed, pass_lift, false)


# ----------------------------------------------------------------------------
# Striking the ball
# ----------------------------------------------------------------------------

## True when this footballer may strike the ball right now: it must genuinely own
## the ball, with one exception - the frame the player runs onto a loose ball, so
## a tap of SHOOT is never swallowed by a frame race.
func _may_strike_ball(ball: Node3D) -> bool:
	if ball == null or not can_play or _possess_lock > 0.0:
		return false
	if ball.get("ball_owner") == self:
		return true
	if not bool(ball.call("is_free")):
		return false
	return _flat_distance_to(global_position, ball.global_position) <= possess_radius


## One kick: release ownership, then set the ball's launch velocity exactly once.
## `lift` is the exact vertical speed given to the ball, so a pass with a zero
## lift stays on the deck and a shot can only rise by the tiny capped amount.
func _kick(ball: Node3D, direction: Vector3, speed: float, lift: float, is_shot: bool) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		flat = _flat_facing()
	flat = flat.normalized()
	var velocity := flat * speed
	velocity.y = maxf(lift, 0.0)
	_owns_ball = false
	_possess_lock = release_lock
	charge = 0.0
	# Fire the kick animation on the exact frame the ball is struck, so the leg
	# swing and the ball leaving the foot are one motion.
	_kick_anim = KICK_ANIM_TIME
	_kick_anim_amp = 1.35 if is_shot else 0.85
	ball.call("launch", velocity, is_shot, shot_hold_time if is_shot else pass_hold_time)
	if DEBUG_KICK:
		print("[KICK] %s is_shot=%s dir=(%.2f,%.2f,%.2f) speed=%.2f lift=%.2f owner_after=%s" % [
			String(name), str(is_shot), flat.x, flat.y, flat.z, speed, lift,
			str(ball.get("ball_owner") != null),
		])


## Where a shot is aimed. Facing the goal guides the ball into the goal mouth;
## facing away simply shoots where the player is looking. There is no random
## element anywhere, so a shot travels exactly where it was aimed.
func _shot_direction() -> Vector3:
	var flat_facing := _flat_facing()
	var to_goal := Vector3(0.0, 0.0, _target_goal_z) - global_position
	to_goal.y = 0.0
	if to_goal.length_squared() < 0.0001:
		return flat_facing
	to_goal = to_goal.normalized()
	if flat_facing.dot(to_goal) > 0.45:
		return (flat_facing + to_goal * 0.65).normalized()
	return flat_facing


## Aim at where a moving team-mate will be when the ball arrives.
func _pass_direction_to(mate, from: Vector3) -> Vector3:
	var mate_velocity: Vector3 = mate.velocity
	var lead := _flat_distance_to(from, mate.global_position) / maxf(pass_speed, 0.01)
	var aim_point: Vector3 = mate.global_position + Vector3(mate_velocity.x, 0.0, mate_velocity.z) * lead
	var to := aim_point - from
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return _flat_facing()
	return to.normalized()


# ----------------------------------------------------------------------------
# Possession - the ball owns the truth, this only asks for it
# ----------------------------------------------------------------------------

func _possession_tick(delta: float) -> void:
	_possess_lock = maxf(_possess_lock - delta, 0.0)
	var ball := _ball_node()
	if ball == null:
		_owns_ball = false
		return

	if not can_play:
		if _owns_ball:
			release_ball()
		return

	var distance := _flat_distance_to(global_position, ball.global_position)
	var rival = _nearest_rival_to_point(ball.global_position)

	if _owns_ball:
		if ball.get("ball_owner") != self:
			# A rival stole it, or the match reset under us.
			_owns_ball = false
			return
		if distance > lose_radius or _rival_clearly_closer(rival, ball, distance):
			release_ball()
			return
		ball.call("set_controlled_point", _foot_target())
		return

	var current_owner = ball.get("ball_owner")
	if current_owner != null and is_instance_valid(current_owner):
		# Owned by somebody else. A rival can be tackled off the ball, but only
		# from close range and only when clearly beaten to the spot.
		if current_owner.team_id != team_id and _possess_lock <= 0.0 and distance <= possess_radius:
			var owner_distance := _flat_distance_to(current_owner.global_position, ball.global_position)
			if distance < owner_distance - steal_margin:
				ball.call("takeover", self, team_id, _foot_target())
				_on_possession_gained()
		return

	if not bool(ball.call("is_free")):
		return
	if _possess_lock > 0.0 or distance > possess_radius:
		return
	if _rival_clearly_closer(rival, ball, distance):
		return
	if not bool(ball.call("claim", self, team_id, _foot_target())):
		return
	_on_possession_gained()


func _on_possession_gained() -> void:
	_owns_ball = true
	# A real settle before the AI plays the ball. This is what stops the frantic
	# ping-pong where every receiver released the ball on the very next frame, so
	# the ball never travelled: the carrier now controls it, dribbles, then plays.
	if not human_controlled:
		_ai_action_clock = 0.75


## Where the ball is wanted: just ahead of the feet, further ahead when running.
func _foot_target() -> Vector3:
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()
	var ratio := clampf(speed / maxf(sprint_speed, 0.01), 0.0, 1.0)
	var ahead := lerpf(carry_distance, carry_distance_fast, ratio)
	return global_position + _flat_facing() * ahead


# ----------------------------------------------------------------------------
# Outfield AI
# ----------------------------------------------------------------------------

func _ai_tick(delta: float) -> void:
	_ai_action_clock = maxf(_ai_action_clock - delta, 0.0)
	var ball := _ball_node()
	if ball == null or not can_play:
		ai_state = AIState.RETURN_TO_POSITION
		var speed := walk_speed if ball != null else walk_speed * 0.6
		_steer_to(home_position, speed, delta)
		_update_facing_from_velocity(0.35)
		return

	if role == "goalkeeper":
		_keeper_tick(delta, ball)
		return
	_outfield_tick(delta, ball)


func _outfield_tick(delta: float, ball: Node3D) -> void:
	var ball_position: Vector3 = ball.global_position

	if _owns_ball:
		_ai_with_ball(delta, ball)
		return

	# My side has it: the closest team-mate supports the ball in space, everyone
	# else keeps their lane and pushes up. No more ten-man pile onto the carrier.
	if _team_has_ball(ball):
		if _is_nearest_teammate_to_ball():
			ai_state = AIState.SUPPORT
			_move_support(delta, ball)
			return
		ai_state = AIState.ATTACK
		_move_team_shape(delta, ball_position, true)
		return

	# A loose ball in my attacking half: only the closest player goes for it.
	if bool(ball.call("is_loose")) and _ball_in_attack_half(ball_position):
		if _is_nearest_teammate_to_ball():
			ai_state = AIState.CHASE_BALL
			_ai_chase(delta, ball, ball_position)
			return
		ai_state = AIState.ATTACK
		_move_team_shape(delta, ball_position, true)
		return

	# Their side has it: hold defensive shape, and only one player presses.
	if _is_team_chaser():
		ai_state = AIState.PRESS
		_ai_chase(delta, ball, ball_position)
		return
	ai_state = AIState.DEFEND
	_move_defend(delta, ball_position)


## My team is in possession (or the ball is mine).
func _team_has_ball(ball: Node3D) -> bool:
	return int(ball.get("possession_team")) == team_id


## True when this footballer is the closest outfielder on their side to the ball,
## with a stable name tiebreak so the choice can never flicker between frames.
## This is the ONLY player allowed to leave the shape and go to the ball, which is
## what stops every AI running at the ball at once.
func _is_nearest_teammate_to_ball() -> bool:
	if human_controlled or role == "goalkeeper":
		return false
	var ball := _ball_node()
	if ball == null:
		return false
	var my_distance := _flat_distance_to(global_position, ball.global_position)
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other):
			continue
		if other.team_id != team_id or other.role == "goalkeeper" or other.human_controlled:
			continue
		var other_distance := _flat_distance_to(other.global_position, ball.global_position)
		if other_distance < my_distance - DUTY_MARGIN:
			return false
		if absf(other_distance - my_distance) <= DUTY_MARGIN and String(other.name) < String(name):
			return false
	return true


## The single designated presser on this side. The human-controlled player is
## never an AI chaser, so the AI can never take over the player being driven.
func _is_team_chaser() -> bool:
	return _is_nearest_teammate_to_ball()


## Close the loose ball down at speed, leading it with its own velocity.
func _ai_chase(delta: float, ball: Node3D, ball_position: Vector3) -> void:
	var ball_velocity: Vector3 = ball.linear_velocity
	var flat_velocity := Vector3(ball_velocity.x, 0.0, ball_velocity.z)
	var intercept := ball_position
	# Only lead a ball that is genuinely travelling. A slow ball is met at its
	# real position, so the chaser converges on it and takes it instead of
	# orbiting just outside possession range forever.
	if flat_velocity.length() > 2.5:
		var lead := clampf(_flat_distance_to(global_position, ball_position) / maxf(sprint_speed, 0.01), 0.0, 0.5)
		intercept = ball_position + flat_velocity * lead
	intercept.x = clampf(intercept.x, -LIMIT_X, LIMIT_X)
	intercept.z = clampf(intercept.z, -LIMIT_Z, LIMIT_Z)
	# Slow up on the approach: finer control at the ball is what turns a chase
	# into real contact and a clean first touch.
	var gap := _flat_distance_to(global_position, intercept)
	_steer_to(intercept + _separation_offset(), sprint_speed if gap > 3.0 else walk_speed, delta)
	_face_toward(ball_position)


## The supporting runner: the one team-mate nearest the ball offers himself in
## space ahead of it, instead of the whole side drifting toward the ball.
func _move_support(delta: float, ball: Node3D) -> void:
	var ball_position: Vector3 = ball.global_position
	var forward := Vector3(0.0, 0.0, _attack_dir.z)
	var side := forward.cross(Vector3.UP).normalized()
	# Offer a real outlet: ahead of the ball and out to one side, never parked
	# directly in front of the carrier, so a passing lane always exists.
	var side_sign := 1.0
	if global_position.x - ball_position.x < -0.5:
		side_sign = -1.0
	elif global_position.x - ball_position.x <= 0.5 and _slot_lane < 0.0:
		side_sign = -1.0
	var target := ball_position + forward * 3.5 + side * side_sign * 4.5
	target.x = clampf(target.x, -LIMIT_X, LIMIT_X)
	target.z = clampf(target.z, -LIMIT_Z, LIMIT_Z)
	var distance := _flat_distance_to(global_position, target)
	_steer_to(target + _separation_offset(), sprint_speed if distance > 5.0 else walk_speed, delta)
	_update_facing_from_velocity(0.4)


## Team shape without the ball-carrier's job: everyone holds their own lane and
## shifts with the ball, pushing up when attacking and dropping when defending.
## This is what keeps the side spread across the pitch instead of collapsing.
func _move_team_shape(delta: float, ball_position: Vector3, attacking: bool) -> void:
	var target := _formation_target(ball_position, attacking)
	_steer_to(target + _separation_offset(), walk_speed, delta)
	_update_facing_from_velocity(0.35)


## The formation point for this player's slot, shaped by where the ball is. Built
## from the slot lane and depth, never from a single shared point, so two players
## never aim at the same spot.
func _formation_target(ball_position: Vector3, attacking: bool) -> Vector3:
	var lane_x: float = _slot_lane * 7.0
	var depth: float = _slot_depth
	var own_half := signf(-_attack_dir.z)
	if attacking:
		depth += _attack_dir.z * attack_push
		depth = clampf(depth, -LIMIT_Z, LIMIT_Z)
		depth = lerpf(depth, ball_position.z, support_follow)
	else:
		depth += _attack_dir.z * defend_drop
		depth = clampf(depth, -LIMIT_Z, LIMIT_Z)
		if not is_zero_approx(own_half) and depth * own_half > -5.0:
			depth = -5.0 * own_half
		depth = lerpf(depth, ball_position.z, defend_follow)
	# Sideways staggered depth, so a back line stands as a line, not a clump.
	depth += _attack_dir.z * 0.9 * clampf(_slot_lane, -1.0, 1.0)
	var lane := lane_x + (ball_position.x - lane_x) * block_slide
	return Vector3(clampf(lane, -LIMIT_X, LIMIT_X), global_position.y, depth)


## Their team has the ball: hold the defensive block and pick up the nearest
## attacker from the slot. Every defender builds from their OWN slot, so the back
## line holds its shape instead of all converging on one cover point.
func _move_defend(delta: float, ball_position: Vector3) -> void:
	var own_goal := Vector3(0.0, 0.0, -_target_goal_z)
	var target := _formation_target(ball_position, false)

	# Pick up the nearest opponent, but only inside this player's own zone, and
	# always position goal-side of them.
	var mark = _nearest_opponent_to_point(global_position)
	if mark != null and _flat_distance_to(global_position, mark.global_position) < 6.5:
		var goal_side: Vector3 = own_goal - mark.global_position
		goal_side.y = 0.0
		if goal_side.length() > 0.1:
			target = target.lerp(mark.global_position + goal_side.normalized() * 1.2, 0.35)

	target.x = clampf(target.x, -LIMIT_X, LIMIT_X)
	target.z = clampf(target.z, -LIMIT_Z, LIMIT_Z)
	var distance := _flat_distance_to(global_position, target)
	_steer_to(target + _separation_offset(), sprint_speed if distance > 6.0 else walk_speed, delta)
	_update_facing_from_velocity(0.4)


## Carrying the ball: control -> dribble -> pass or shoot, decided by the
## situation, never randomly.
func _ai_with_ball(delta: float, ball: Node3D) -> void:
	if _ai_action_clock <= 0.0:
		var goal := Vector3(0.0, 0.0, _target_goal_z)
		if _flat_distance_to(global_position, goal) <= ai_shoot_range:
			ai_state = AIState.SHOOT
			_ai_shoot(ball, goal)
			return
		var mate = _best_pass_target(true)
		if mate != null and _pass_helps(mate, goal):
			ai_state = AIState.PASS
			_ai_pass(ball, mate)
			return
	ai_state = AIState.DRIBBLE
	_move_dribble(delta)


func _move_dribble(delta: float) -> void:
	var goal := Vector3(0.0, 0.0, _target_goal_z)
	var to_goal := goal - global_position
	to_goal.y = 0.0
	if to_goal.length_squared() < 0.0001:
		to_goal = _attack_dir
	to_goal = to_goal.normalized()
	# If a defender is standing in the way, cut around them.
	var blocker = _nearest_opponent_in_front(to_goal, 3.2)
	if blocker != null:
		var side := to_goal.cross(Vector3.UP).normalized()
		var away: Vector3 = global_position - blocker.global_position
		away.y = 0.0
		if away.dot(side) < 0.0:
			side = -side
		to_goal = (to_goal + side * 0.85).normalized()
	var target := global_position + to_goal * 3.0 + _separation_offset()
	target.x = clampf(target.x, -LIMIT_X, LIMIT_X)
	target.z = clampf(target.z, -LIMIT_Z, LIMIT_Z)
	_steer_to(target, sprint_speed * 0.9, delta)
	_face_toward(global_position + to_goal)


func _ai_shoot(ball: Node3D, goal: Vector3) -> void:
	var keeper = _opponent_keeper()
	var aim := goal
	if keeper != null:
		# Aim into the half of the goal the keeper is not standing in.
		aim.x = clampf(-keeper.global_position.x * 0.9, -2.2, 2.2)
	var direction := aim - ball.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		direction = _attack_dir
	_kick(ball, direction, ai_shot_power, ai_shot_lift, true)
	_ai_action_clock = 0.6


func _ai_pass(ball: Node3D, mate) -> void:
	_kick(ball, _pass_direction_to(mate, ball.global_position), pass_speed, pass_lift, false)
	_ai_action_clock = 0.5


## A pass is only worth playing if it moves the ball closer to goal.
func _pass_helps(mate, goal: Vector3) -> bool:
	var mine := _flat_distance_to(global_position, goal)
	var theirs := _flat_distance_to(mate.global_position, goal)
	return theirs + 2.5 < mine


# ----------------------------------------------------------------------------
# Goalkeeper AI - its own controller, never in charge of the human player
# ----------------------------------------------------------------------------

func _keeper_tick(delta: float, ball: Node3D) -> void:
	var ball_position: Vector3 = ball.global_position
	var own_half := signf(home_position.z)
	if is_zero_approx(own_half):
		own_half = 1.0

	var target_x := clampf(ball_position.x * 0.45, -2.0, 2.0)
	var target_z := home_position.z
	var ball_distance := _flat_distance_to(global_position, ball_position)

	if can_play and ball_distance < 10.0:
		# Narrow the angle, but never abandon the goal line.
		var out := Vector3(ball_position.x, 0.0, ball_position.z) - Vector3(target_x, 0.0, target_z)
		out.y = 0.0
		if out.length() > 0.1:
			out = out.normalized() * minf(3.2, ball_distance * 0.5)
			target_z += out.z
			target_x = clampf(target_x + out.x * 0.4, -2.6, 2.6)

	# Never wander out of the area or behind the goal line.
	var near := minf(11.0 * own_half, 15.6 * own_half)
	var far := maxf(11.0 * own_half, 15.6 * own_half)
	target_z = clampf(target_z, near, far)

	ai_state = AIState.DEFEND
	_steer_to(Vector3(target_x, global_position.y, target_z), sprint_speed * 0.8, delta)
	_face_toward(Vector3(ball_position.x, global_position.y, ball_position.z))

	if can_play and _owns_ball and _ai_action_clock <= 0.0 and ball_distance <= 1.7:
		_ai_clear(ball)


## Keepers never dribble out: they clear it up the pitch, preferably to a
## team-mate who is further forward.
func _ai_clear(ball: Node3D) -> void:
	var mate = _best_pass_target(false)
	if mate != null and _pass_helps(mate, Vector3(0.0, 0.0, _target_goal_z)):
		_kick(ball, _pass_direction_to(mate, ball.global_position), keeper_clear_power, keeper_clear_lift, false)
	else:
		var direction := Vector3(0.0, 0.0, _target_goal_z) - ball.global_position
		direction.y = 0.0
		if direction.length_squared() < 0.0001:
			direction = _attack_dir
		_kick(ball, direction, keeper_clear_power, keeper_clear_lift, false)
	_ai_action_clock = 1.0


# ----------------------------------------------------------------------------
# Shared helpers
# ----------------------------------------------------------------------------

func _ball_node() -> Node3D:
	if _ball == null or not is_instance_valid(_ball):
		_ball = get_tree().get_first_node_in_group("ball")
	return _ball


## Closest opponent to the ball, for the possession contest.
func _nearest_rival_to_point(point: Vector3):
	var closest = null
	var closest_distance := 1.0e9
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other) or other.team_id == team_id:
			continue
		var distance := _flat_distance_to(other.global_position, point)
		if distance < closest_distance:
			closest_distance = distance
			closest = other
	return closest


func _rival_clearly_closer(rival, ball: Node3D, my_distance: float) -> bool:
	if rival == null:
		return false
	return _flat_distance_to(rival.global_position, ball.global_position) < my_distance - steal_margin


## Closest opponent to a point, for defensive marking.
func _nearest_opponent_to_point(point: Vector3):
	var closest = null
	var closest_distance := 1.0e9
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other) or other.team_id == team_id:
			continue
		if other.role == "goalkeeper":
			continue
		var distance := _flat_distance_to(other.global_position, point)
		if distance < closest_distance:
			closest_distance = distance
			closest = other
	return closest


func _nearest_opponent_in_front(direction: Vector3, range_limit: float):
	var closest = null
	var closest_distance := range_limit
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other) or other.team_id == team_id:
			continue
		if other.role == "goalkeeper":
			continue
		var to_other: Vector3 = other.global_position - global_position
		to_other.y = 0.0
		var distance := to_other.length()
		if distance > range_limit or distance < 0.01:
			continue
		if to_other.normalized().dot(direction) < 0.7:
			continue
		if distance < closest_distance:
			closest_distance = distance
			closest = other
	return closest


func _opponent_keeper():
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other):
			continue
		if other.team_id != team_id and other.role == "goalkeeper":
			return other
	return null


## Best team-mate to pass to. `forward_only` keeps the human's PASS aimed at
## somebody in front of them, as the brief requires.
func _best_pass_target(forward_only: bool):
	var ball := _ball_node()
	if ball == null:
		return null
	var goal := Vector3(0.0, 0.0, _target_goal_z)
	var from: Vector3 = ball.global_position
	var facing := _flat_facing()
	var best = null
	var best_score := 0.0
	var fallback = null
	var fallback_distance := 1.0e9
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other) or other.team_id != team_id:
			continue
		if other.role == "goalkeeper":
			continue
		var to_mate: Vector3 = other.global_position - global_position
		to_mate.y = 0.0
		var distance := to_mate.length()
		if distance < 2.0 or distance > pass_range:
			continue
		var ahead := to_mate.normalized().dot(facing)
		# Square and short back passes are legitimate football. Only the human's
		# assisted PASS stays forward-facing, and even that now accepts a square
		# ball instead of demanding a big gain toward goal.
		if forward_only and ahead < -0.2:
			continue
		if distance < fallback_distance:
			fallback_distance = distance
			fallback = other
		# An opponent sitting in the lane kills the pass; an open ball gets played.
		var clearness := _pass_lane_clearness(from, other.global_position)
		var gain := _flat_distance_to(from, goal) - _flat_distance_to(other.global_position, goal)
		var score := gain + clearness * 8.0 + ahead * 1.5
		if clearness < 0.2:
			score -= 12.0
		if score > best_score:
			best_score = score
			best = other
	if best != null:
		return best
	if forward_only:
		return null
	return fallback


## How open the straight lane from `from` to `to` is: 0 is blocked, 1 is clear.
## O(opponents) with no allocation, cheap enough to run every frame on mobile.
func _pass_lane_clearness(from: Vector3, to: Vector3) -> float:
	var segment := to - from
	var length := segment.length()
	if length < 0.2:
		return 1.0
	var dir := segment / length
	var worst := 1.0
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other) or other.team_id == team_id:
			continue
		var to_other: Vector3 = other.global_position - from
		to_other.y = 0.0
		var along := to_other.dot(dir)
		if along < 0.3 or along > length - 0.3:
			continue
		var perpendicular := (to_other - dir * along).length()
		worst = minf(worst, clampf(perpendicular / 1.6, 0.0, 1.0))
	return worst


## Push away from any footballer standing too close, so ten bodies on a small
## pitch spread out instead of piling onto one spot.
func _separation_offset() -> Vector3:
	var push := Vector3.ZERO
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other):
			continue
		var away: Vector3 = global_position - other.global_position
		away.y = 0.0
		var distance := away.length()
		if distance > 0.01 and distance < 1.2:
			push += (away / distance) * (1.2 - distance)
	# Hard cap: separation may nudge a target, it may never drag a player off its
	# football job. This is what stopped ten bodies drifting with no purpose.
	if push.length() > SEPARATION_MAX:
		push = push.normalized() * SEPARATION_MAX
	return push


func _ball_in_attack_half(ball_position: Vector3) -> bool:
	return (ball_position.z - global_position.z) * _attack_dir.z > 0.0


## Hard boundary: every footballer stays on the deck and inside the pitch.
func _clamp_to_pitch() -> void:
	var position := global_position
	position.x = clampf(position.x, -LIMIT_X, LIMIT_X)
	position.z = clampf(position.z, -LIMIT_Z, LIMIT_Z)
	position.y = clampf(position.y, 0.0, 2.5)
	if not position.is_equal_approx(global_position):
		global_position = position


## Formation slot from the authored home spot. `_slot_lane` is the player's lane
## across the pitch and `_slot_depth` is how far up it they naturally sit, so
## every AI target can be built from the shape instead of from the ball.
func _apply_slot() -> void:
	_slot_lane = clampf(home_position.x / 7.0, -1.0, 1.0)
	_slot_depth = home_position.z


func _steer_to(target: Vector3, speed: float, delta: float) -> void:
	var to_target := target - global_position
	to_target.y = 0.0
	var distance := to_target.length()
	var desired := Vector3.ZERO
	# Ease into the target over the last metres and stand still inside the
	# deadzone, instead of hunting around a point the player cannot settle on.
	if distance > ARRIVE_DEADZONE:
		desired = to_target / distance * (speed * clampf(distance / ARRIVE_RADIUS, 0.0, 1.0))
	velocity.x = move_toward(velocity.x, desired.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, desired.z, acceleration * delta)


func _input_to_world(input: Vector2) -> Vector3:
	var forward := _flat_forward()
	var right := forward.cross(Vector3.UP).normalized()
	var dir := right * input.x + forward * (-input.y)
	dir.y = 0.0
	if dir.length_squared() > 0.0001:
		dir = dir.normalized()
	return dir


func _flat_forward() -> Vector3:
	if _camera != null:
		var forward := -_camera.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			return forward.normalized()
	return Vector3(0.0, 0.0, -1.0)


func _flat_facing() -> Vector3:
	var flat := Vector3(_facing.x, 0.0, _facing.z)
	if flat.length_squared() < 0.0001:
		return _attack_dir
	return flat.normalized()


func _face_toward(point: Vector3) -> void:
	var to_point := point - global_position
	to_point.y = 0.0
	if to_point.length_squared() > 0.04:
		_facing = to_point.normalized()
	_apply_facing(0.35)


func _update_facing_from_velocity(weight: float) -> void:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var speed := flat.length()
	# Standing still is not a direction. Below the jog threshold the heading is
	# held, so leftover velocity noise can never spin a player on the spot.
	if speed < FACING_MIN_SPEED:
		return
	_facing = flat / speed
	_apply_facing(weight)


func _apply_facing(weight: float) -> void:
	if _visual == null:
		return
	var yaw := atan2(-_facing.x, -_facing.z)
	var diff := angle_difference(_visual.rotation.y, yaw)
	# The deadzone comes first: a heading error of a few degrees is not a reason to
	# move at all, so a wobbling target can never make a footballer pirouette on
	# the spot. Past the deadzone the pivot is rate limited instead of snapping, so
	# he turns at a believable speed whatever the frame rate.
	if absf(diff) <= FACING_DEADZONE:
		return
	var max_step := TURN_RATE * _last_delta * clampf(weight * 2.5, 0.05, 1.0)
	_visual.rotation.y += clampf(diff, -max_step, max_step)


func _flat_distance_to(from: Vector3, to: Vector3) -> float:
	var dx := to.x - from.x
	var dz := to.z - from.z
	return sqrt(dx * dx + dz * dz)


## Player-to-player collision. Footballers are moved with move_and_slide, and the
## bodies on one side share a collision layer, so a body can end up inside a
## team-mate. This separates them: inside CONTACT_RADIUS the inward part of the
## velocity is cancelled so a jam resolves, and between CONTACT_RADIUS and
## SEPARATION_RADIUS the bodies steer apart. It only ever REMOVES movement and
## nudges overlap out at a capped speed, so it can never add force or throw a
## body - which is what stops physics explosions.
func _resolve_contact() -> void:
	var radius := CONTACT_RADIUS * 2.0
	for other in get_tree().get_nodes_in_group("footballers"):
		if other == self or not is_instance_valid(other):
			continue
		var away: Vector3 = global_position - other.global_position
		away.y = 0.0
		var distance := away.length()
		if distance > radius or distance < 1.0e-4:
			continue
		var direction := away / distance
		var overlap := radius - distance
		global_position += direction * minf(overlap, 4.0 * get_physics_process_delta_time())
		var inward := velocity.dot(-direction)
		if inward > 0.0:
			velocity += direction * inward


func _advance_run_cycle(delta: float) -> void:
	if _kick_anim > 0.0:
		_kick_anim = maxf(_kick_anim - delta, 0.0)
		# A single forward swing that peaks halfway through, then settles back
		# into the stride. Nothing exaggerated: the leg travels, the body does not.
		var t := 1.0 - (_kick_anim / KICK_ANIM_TIME)
		var swing := sin(t * PI) * _kick_anim_amp
		if _leg_r != null:
			_leg_r.rotation.x = swing
		if _leg_l != null:
			_leg_l.rotation.x = -swing * 0.3
		if _arm_l != null:
			_arm_l.rotation.x = -swing * 0.55
		if _arm_r != null:
			_arm_r.rotation.x = swing * 0.4
		return
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()
	_run_phase += delta * (3.5 + speed * 1.2)
	var swing := sin(_run_phase) * clampf(speed / sprint_speed, 0.0, 1.0) * 0.7
	if _leg_l != null:
		_leg_l.rotation.x = swing
	if _leg_r != null:
		_leg_r.rotation.x = -swing
	if _arm_l != null:
		_arm_l.rotation.x = -swing * 0.75
	if _arm_r != null:
		_arm_r.rotation.x = swing * 0.75


# ----------------------------------------------------------------------------
# Team kit colours
# ----------------------------------------------------------------------------

static func _material(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if _material_cache.has(key):
		return _material_cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	_material_cache[key] = mat
	return mat


func _jersey_color() -> Color:
	if role == "goalkeeper":
		return BLUE_KEEPER if team_id == TEAM_BLUE else RED_KEEPER
	return BLUE_JERSEY if team_id == TEAM_BLUE else RED_JERSEY


func _shorts_color() -> Color:
	return BLUE_SHORTS if team_id == TEAM_BLUE else RED_SHORTS


func _paint() -> void:
	if _visual == null:
		return
	var jersey := _material(_jersey_color())
	var shorts := _material(_shorts_color())
	var skin := _material(SKIN)
	var hair := _material(HAIR)
	var sock := _material(SOCK)
	_paint_part("Chest", jersey)
	_paint_part("Shorts", shorts)
	_paint_part("Head", skin)
	_paint_part("Hair", hair)
	_paint_part("ArmL", skin)
	_paint_part("ArmR", skin)
	_paint_part("LegL", sock)
	_paint_part("LegR", sock)


func _paint_part(part_name: String, mat: StandardMaterial3D) -> void:
	if _visual == null:
		return
	# find_child (owned=false) so limbs nested under their swing pivots are found.
	var node := _visual.find_child(part_name, true, false)
	if node is GeometryInstance3D:
		node.material_override = mat
