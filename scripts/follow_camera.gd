extends Camera3D
## Fixed-angle match camera. It tracks the midpoint of the controlled player and
## the ball with a clamp on the focus point, so the horizon stays level (roll is
## always zero) and the action stays framed on a phone screen.

@export var player_path: NodePath = NodePath("../TeamBlue/Player")
@export var ball_path: NodePath = NodePath("../Ball")
## Lower and closer than a stadium camera: on a phone the action has to fill the
## screen. Height 16.5 and back 13.5 keeps the ball around 20-26 m away, which
## holds the controlled player, the ball and the surrounding team-mates in frame
## without the players shrinking into specks.
@export var offset: Vector3 = Vector3(0.0, 13.5, 11.5)
## How strongly the focus follows the ball rather than the player, and how fast it
## closes the gap. A bit more ball bias plus quicker smoothing keeps a fast ball
## in view instead of letting it run off the top of the screen.
@export var ball_weight: float = 0.6
## Extra ball bias once the ball is travelling fast, so a struck pass or shot
## stays framed instead of running off the edge of a phone screen.
@export var ball_weight_fast: float = 0.85
@export var ball_fast_speed: float = 9.0
@export var smoothing: float = 5.0
## The focus point is clamped so the camera never drifts far past the touchline.
## Wide enough that the ball stays framed at the corners of the pitch.
@export var focus_min: Vector2 = Vector2(-10.0, -13.0)
@export var focus_max: Vector2 = Vector2(10.0, 13.0)

var _player: Node3D
var _ball: Node3D
var _focus: Vector3 = Vector3.ZERO


func _ready() -> void:
	_player = get_node_or_null(player_path) as Node3D
	_ball = get_node_or_null(ball_path) as Node3D
	_focus = _compute_focus()
	global_position = _focus + offset
	_look()


func _process(delta: float) -> void:
	var weight := clampf(smoothing * delta, 0.0, 1.0)
	_focus = _focus.lerp(_compute_focus(), weight)
	global_position = global_position.lerp(_focus + offset, weight)
	_look()


func _compute_focus() -> Vector3:
	if _player == null:
		return global_position - offset
	var focus := _player.global_position
	if _ball != null:
		focus = focus.lerp(_ball.global_position, _current_ball_weight())
	focus.x = clampf(focus.x, focus_min.x, focus_max.x)
	focus.z = clampf(focus.z, focus_min.y, focus_max.y)
	focus.y = 0.0
	return focus


## How strongly the focus leans on the ball this frame. A slow ball sits near the
## controlled player; once it is struck, the ball takes over the framing so it can
## never leave the screen. Reads the ball's own velocity, never writes anything.
func _current_ball_weight() -> float:
	var speed := 0.0
	var raw = _ball.get("linear_velocity")
	if raw is Vector3:
		var flat: Vector3 = raw
		speed = Vector2(flat.x, flat.z).length()
	var t := clampf(speed / maxf(ball_fast_speed, 0.01), 0.0, 1.0)
	return lerpf(ball_weight, ball_weight_fast, t)


## Hand the camera a new focus player. The match script calls this the moment
## SWITCH gives control to another Blue player, so the camera keeps following
## whoever the human is actually driving instead of the kick-off player.
func set_player(player: Node3D) -> void:
	if player == null or not is_instance_valid(player):
		return
	_player = player


func _look() -> void:
	if global_position.distance_squared_to(_focus) < 0.01:
		return
	look_at(_focus, Vector3.UP)
