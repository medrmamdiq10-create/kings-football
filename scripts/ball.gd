class_name Ball
extends RigidBody3D
## The match ball: ONE independent rigid body with ONE explicit state machine.
##
## This file is the single authority for the ball. Exactly one footballer may own
## it at a time (`ball_owner`), and only three things may ever change how it
## moves:
##   * the physics engine itself - gravity, rolling, friction and bouncing,
##   * `launch()` - the one velocity set at the instant of a pass or a shot,
##   * the carry inside `_integrate_forces()` - a bounded horizontal nudge toward
##     the owner's feet while the ball is controlled.
##
## There is no parenting, no per-frame teleporting, no long-range attraction and
## no second script driving the ball: a player only gets the ball by physically
## being close to it, and any body can knock it off them again.
##
## The value limits below are ceilings, not behaviour. Normal play never reaches
## them; they exist so the ball can never become unstable, never launch itself
## into the sky and never creep forever.

enum State {
	FREE,        ## Loose: gravity, rolling, friction and bouncing only.
	CONTROLLED,  ## One footballer is carrying it at their feet.
	PASSING,     ## Just left the foot on a pass; settles back to FREE.
	SHOOTING,    ## Just left the foot on a shot; settles back to FREE.
}

const NO_OWNER: int = -1
const TEAM_BLUE: int = 0
const TEAM_RED: int = 1

## Ball centre height when the sphere rests on the deck. Matches the scene's
## collision sphere radius, so "on the ground" is a real measurement.
const REST_HEIGHT: float = 0.22

@export_group("Carry")
## Velocity target per metre of error between the ball and the wanted foot
## point. Deliberately soft: the ball is nudged toward the foot, never glued.
@export var carry_spring: float = 4.0
## Absolute ceiling on a carried ball's speed, whatever the owner is doing.
@export var carry_max_speed: float = 11.0
## How fast the carry may change the ball's speed, in m/s per second. This is
## what keeps the carry a push and not a snap: the ball takes a moment to catch
## up, so close control reads as football touches.
@export var carry_max_accel: float = 16.0
## Radius used to turn a struck ball's speed into rolling spin. It matches the
## collision sphere, so a kicked ball rolls from the first moment instead of
## skidding flat across the grass.
@export var roll_radius: float = 0.22

@export_group("Limits")
## Fastest the ball may ever travel, in m/s. A powerful shot can reach this;
## nothing can exceed it.
@export var max_speed: float = 26.0
## Fastest the ball may ever travel straight up, in m/s.
@export var max_upward_speed: float = 12.0
## A ball that was NOT struck may not be popped upward faster than this. A body
## pressing on a loose ball used to squeeze it into the air; this is the ceiling
## that stops that, while a kick and its rebounds keep their full loft. It sits
## high enough that a genuine rebound off a post or a defender still reads as a
## bounce - 3 m/s is a half-metre hop - and only a squeeze-pop is clipped.
@export var ground_pop_limit: float = 3.0
## How long after a kick the ball keeps unrestricted loft - one full flight plus
## its first rebounds. Past that it is treated as a loose ball again.
@export var loft_window: float = 2.5
## Grass rolling friction, in m/s per second, applied to any ball on the deck.
## This is what replaces the old heavy linear damping: air drag stays light so a
## lofted shot keeps its flight, while a ball on the ground slows the way a real
## one does - a firm 10 m/s pass rolls out in roughly 15 m - and anything under
## `roll_stop_speed` settles to a genuine stop instead of creeping forever.
@export var roll_stop_speed: float = 3.0
@export var roll_resistance: float = 3.2

@export_group("Safety")
## Escape net. The pitch walls and the goal frame do the real containment; these
## bounds only catch a ball that has genuinely left the world, so it can never
## fall out of the arena or fly away and vanish.
@export var escape_x: float = 13.5
@export var escape_z: float = 21.0
@export var escape_y: float = 9.0

var spawn_position: Vector3 = Vector3.ZERO
var state: int = State.FREE
## The single authority for who may steer the ball. Null while it is loose.
var ball_owner: Node3D = null
## NO_OWNER, TEAM_BLUE or TEAM_RED. Read by the match script for bookkeeping.
var possession_team: int = NO_OWNER
## Where the owner wants the ball to sit, in flat world space.
var controlled_point: Vector3 = Vector3.ZERO

var _action_clock: float = 0.0
## Countdown of unrestricted loft after a kick.
var _loft_window: float = 0.0


func _ready() -> void:
	spawn_position = global_position
	# A resting ball is allowed to sleep: it saves physics work on mobile and it
	# cannot drift while asleep. It is woken the moment anybody claims it.
	can_sleep = true


func _physics_process(delta: float) -> void:
	_loft_window = maxf(_loft_window - delta, 0.0)

	# A pass or a shot only stays tagged for a moment. After that the ball is
	# simply loose again and ordinary physics owns it.
	if state == State.PASSING or state == State.SHOOTING:
		_action_clock = maxf(_action_clock - delta, 0.0)
		if _action_clock <= 0.0:
			state = State.FREE

	# The owner can be switched, frozen or removed under us at any time.
	if state == State.CONTROLLED and (ball_owner == null or not is_instance_valid(ball_owner)):
		_clear_owner()

	if _has_escaped():
		_recover()


# ---------------------------------------------------------------------------
# Public API - the only way anything else touches the ball
# ---------------------------------------------------------------------------

## True while nobody owns the ball, whatever the physics state tag says.
func is_loose() -> bool:
	return ball_owner == null


func is_free() -> bool:
	return state == State.FREE


func owner_is(who: Node3D) -> bool:
	return ball_owner == who


## Take a genuinely free ball. Refused while the ball is mid-pass or mid-shot,
## and refused if somebody else already owns it - two players can never both
## believe they are carrying the ball.
func claim(who: Node3D, team: int, point: Vector3) -> bool:
	if state != State.FREE:
		return false
	if ball_owner != null and is_instance_valid(ball_owner) and ball_owner != who:
		return false
	_set_owner(who, team, point)
	return true


## Steal the ball from a rival. Only ever called after the challenger has proved
## it is clearly closer to the ball than the current owner.
func takeover(who: Node3D, team: int, point: Vector3) -> void:
	_set_owner(who, team, point)


func set_controlled_point(point: Vector3) -> void:
	controlled_point = point


## Drop ownership without kicking it - a tackle, a switch of player, a reset.
func release() -> void:
	_clear_owner()


## One controlled launch: release ownership, then give the ball its speed. The
## ball leaves the foot at exactly the speed the kicker asked for, so a pass with
## no lift sits on the deck and a shot rises only by its capped amount, whatever
## the mass is. Anything past the ball's own limits is trimmed here, so no caller
## can hand the ball an unstable speed.
func launch(velocity: Vector3, is_shot: bool, hold_time: float) -> void:
	_clear_owner()
	state = State.SHOOTING if is_shot else State.PASSING
	_action_clock = maxf(hold_time, 0.0)
	# Real loft is only ever granted here, at the moment of the strike.
	_loft_window = loft_window
	# A freshly placed ball may still be frozen or asleep; a kick must always
	# take, so both are cleared before the velocity is written.
	freeze = false
	sleeping = false
	can_sleep = true
	linear_velocity = _within_limits(velocity)
	angular_velocity = _roll_spin(linear_velocity)


## The angular velocity that makes a struck ball roll instead of skidding. It is
## derived from the travel direction alone, so the spin is fully deterministic and
## can never add a random sideways curve to a pass or a shot.
func _roll_spin(velocity: Vector3) -> Vector3:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var speed := flat.length()
	if speed < 0.05:
		return Vector3.ZERO
	var axis := flat.normalized().cross(Vector3.UP)
	return axis * (-speed / maxf(roll_radius, 0.01))


func reset_to_spawn() -> void:
	reset_to(spawn_position)


func reset_to(target: Vector3) -> void:
	freeze = true
	_clear_owner()
	global_position = target
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze = false
	sleeping = false


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _set_owner(who: Node3D, team: int, point: Vector3) -> void:
	ball_owner = who
	possession_team = team
	state = State.CONTROLLED
	controlled_point = point
	# A carried ball must never fall asleep mid-dribble, or the carry would stop
	# being evaluated while the player kept running.
	can_sleep = false
	sleeping = false


func _clear_owner() -> void:
	ball_owner = null
	possession_team = NO_OWNER
	if state == State.CONTROLLED:
		state = State.FREE
	can_sleep = true


## Trim any velocity to the ball's own ceilings.
func _within_limits(velocity: Vector3) -> Vector3:
	var flat := Vector2(velocity.x, velocity.z)
	var speed := flat.length()
	if speed > max_speed:
		flat = flat.normalized() * max_speed
	return Vector3(flat.x, minf(velocity.y, max_upward_speed), flat.y)


func _has_escaped() -> bool:
	var position := global_position
	return absf(position.x) > escape_x or absf(position.z) > escape_z \
		or position.y > escape_y or position.y < -3.0


func _recover() -> void:
	_clear_owner()
	global_position = spawn_position
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false


## The single writer of the ball's motion. Runs on the physics thread, so the
## carry, the ceilings and the rolling resistance all shape the ball in one
## place instead of several scripts fighting over it.
func _integrate_forces(body_state: PhysicsDirectBodyState3D) -> void:
	var xform := body_state.transform
	var velocity := body_state.linear_velocity
	var touched := false

	# --- Carrying. A soft horizontal nudge toward the owner's foot target. The
	#     vertical axis is never touched, so a carried ball can never gain height
	#     and fly, and the ball stays a real body that can be knocked loose. ----
	if state == State.CONTROLLED and ball_owner != null and is_instance_valid(ball_owner):
		var owner_flat := Vector3.ZERO
		if ball_owner is CharacterBody3D:
			var raw: Vector3 = ball_owner.velocity
			owner_flat = Vector3(raw.x, 0.0, raw.z)
		var to_target := controlled_point - xform.origin
		to_target.y = 0.0
		# The owner's own speed is fed forward so a running player's ball keeps
		# up instead of lagging, and the error term is what closes the gap. The
		# proportional term self-limits as the error shrinks, so the ball settles
		# at the foot instead of running away.
		var desired := owner_flat + to_target * carry_spring
		if desired.length() > carry_max_speed:
			desired = desired.normalized() * carry_max_speed
		var flat := Vector3(velocity.x, 0.0, velocity.z)
		var correction := (desired - flat).limit_length(carry_max_accel * body_state.step)
		velocity.x = flat.x + correction.x
		velocity.z = flat.z + correction.z
		touched = true

	# --- Ceilings. Fast is allowed; unbounded is not. -------------------------
	var horizontal := Vector2(velocity.x, velocity.z)
	var horizontal_speed := horizontal.length()
	if horizontal_speed > max_speed:
		horizontal = horizontal.normalized() * max_speed
		velocity.x = horizontal.x
		velocity.z = horizontal.y
		touched = true
	if velocity.y > max_upward_speed:
		velocity.y = max_upward_speed
		touched = true

	# --- Loft belongs to the kick alone. A body pressing on a loose ball must
	#     never squeeze it into the air, which is what used to make the ball jump
	#     for no reason at all. ----------------------------------------------
	if _loft_window <= 0.0 and velocity.y > ground_pop_limit:
		velocity.y = ground_pop_limit
		touched = true

	# --- Rolling resistance. A slow ball on the deck settles and stops instead
	#     of creeping across the grass forever. -------------------------------
	if xform.origin.y <= REST_HEIGHT + 0.08:
		var ground_speed := sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
		if ground_speed > 0.0001 and ground_speed < roll_stop_speed:
			var remaining: float = maxf(ground_speed - roll_resistance * body_state.step, 0.0)
			var shrink: float = remaining / ground_speed
			velocity.x *= shrink
			velocity.z *= shrink
			touched = true

	if touched:
		body_state.linear_velocity = velocity
