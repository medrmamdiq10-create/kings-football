extends CharacterBody3D
## Street-football prototype player.
## Camera-relative movement, sprint, a soft "possession" dribble and a
## charge-and-release shot. Keyboard (WASD + Space) and on-screen touch controls
## feed the same input path.

@export var walk_speed: float = 7.0
@export var sprint_speed: float = 10.5
@export var acceleration: float = 45.0
@export var turn_speed: float = 12.0
@export var kick_range: float = 2.1
@export var min_kick_power: float = 7.0
@export var max_kick_power: float = 17.0
@export var charge_time: float = 0.85
@export var kick_loft: float = 0.26
@export var dribble_radius: float = 1.9
@export var dribble_grip: float = 7.0
@export var camera_path: NodePath = NodePath("../Camera3D")
@export var ball_path: NodePath = NodePath("../Ball")
@export var touch_controls_path: NodePath = NodePath("../HUD/TouchControls")
@export var visual_path: NodePath = NodePath("Visual")

var charge: float = 0.0
var can_play: bool = true

var _gravity: float = 9.8
var _ball
var _touch
var _camera: Camera3D
var _visual: Node3D
var _prev_shoot: bool = false
var _facing: Vector3 = Vector3(0.0, 0.0, -1.0)
var _spawn_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_ball = get_node_or_null(ball_path)
	_touch = get_node_or_null(touch_controls_path)
	_camera = get_node_or_null(camera_path) as Camera3D
	_visual = get_node_or_null(visual_path) as Node3D
	_spawn_position = global_position
	_facing = _flat_forward()


func _physics_process(delta: float) -> void:
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= _gravity * delta

	var input := Vector2.ZERO
	if can_play:
		input = _read_move_input()
	var direction := _input_to_world(input)

	var analog := clampf(input.length(), 0.0, 1.0)
	if direction.length_squared() < 0.0001:
		analog = 0.0

	var target_speed := walk_speed
	if can_play and _sprint_held():
		target_speed = sprint_speed
	target_speed *= analog

	var desired := direction * target_speed
	velocity.x = move_toward(velocity.x, desired.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, desired.z, acceleration * delta)
	move_and_slide()

	_update_facing(delta)
	_update_shot(delta)


func set_play_enabled(value: bool) -> void:
	can_play = value
	if not value:
		charge = 0.0
		velocity.x = 0.0
		velocity.z = 0.0


func respawn_at_spawn() -> void:
	global_position = _spawn_position
	velocity = Vector3.ZERO
	charge = 0.0
	_facing = _flat_forward()
	if _visual != null:
		_visual.rotation.y = atan2(-_facing.x, -_facing.z)


## 0.0 to 1.0 charge level of the current shot, for HUD/feedback later on.
func shot_charge() -> float:
	return charge


func _read_move_input() -> Vector2:
	var keyboard := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if keyboard.length() > 0.05:
		return keyboard
	if _touch != null:
		return _touch.move_vector
	return Vector2.ZERO


func _sprint_held() -> bool:
	if Input.is_action_pressed("sprint"):
		return true
	if _touch != null:
		return bool(_touch.sprint_active)
	return false


func _flat_forward() -> Vector3:
	if _camera != null:
		var forward := -_camera.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			return forward.normalized()
	return Vector3(0.0, 0.0, -1.0)


func _input_to_world(input: Vector2) -> Vector3:
	var forward := _flat_forward()
	var right := forward.cross(Vector3.UP).normalized()
	var dir := right * input.x + forward * (-input.y)
	dir.y = 0.0
	if dir.length_squared() > 0.0001:
		dir = dir.normalized()
	return dir


func _update_facing(delta: float) -> void:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() > 0.25:
		_facing = flat.normalized()
	if _visual == null:
		return
	var yaw := atan2(-_facing.x, -_facing.z)
	_visual.rotation.y = lerp_angle(_visual.rotation.y, yaw, clampf(turn_speed * delta, 0.0, 1.0))


func _update_shot(delta: float) -> void:
	var shoot_held := Input.is_action_pressed("shoot")
	if _touch != null:
		# The on-screen SHOOT button wins while it is held, and a thumb-stick drag
		# must never charge a shot: touch input also emulates a mouse press, which
		# would otherwise read as the "shoot" action while the player is just moving.
		if _touch.shoot_down:
			shoot_held = true
		elif _touch.stick_active:
			shoot_held = false
	if not can_play:
		shoot_held = false

	if shoot_held:
		charge = minf(charge + delta / charge_time, 1.0)
	elif _prev_shoot:
		_try_kick()
	_prev_shoot = shoot_held


## Ball interaction removed on purpose.
##
## This street-football prototype predates the match and is NOT mounted in any
## scene. It used to write straight into the ball: an impulse when SHOOT was
## released and a velocity lerp that dragged the ball toward the player. That is
## a second system driving the same body, which is exactly what the ball system
## must never have. The ball now belongs entirely to res://scripts/ball.gd, and
## a footballer goes through its API (claim / launch / release) as
## res://scripts/footballer.gd does.
##
## The charge state is kept so the HUD-facing `shot_charge()` still reads
## correctly; the kick itself is a no-op if this script is ever mounted again.
func _try_kick() -> void:
	charge = 0.0
