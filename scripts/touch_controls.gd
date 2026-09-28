class_name TouchControls
extends Control
## Mobile-first on-screen controls: a floating thumb-stick on the left side, a
## hold-to-charge SHOOT button, a tap-to-PASS button and a SWITCH button to hand
## control to another Blue player. Touch and mouse both work, so the match is
## playable on desktop too.

signal shoot_pressed
signal shoot_released
signal pass_pressed
signal switch_pressed

@export var stick_radius: float = 118.0
@export var knob_radius: float = 48.0
@export var edge_margin: float = 56.0
## Pushing the thumb-stick past this fraction of its radius counts as sprint.
@export var sprint_threshold: float = 0.86

var move_vector: Vector2 = Vector2.ZERO
var shoot_down: bool = false
var pass_down: bool = false
var stick_active: bool = false
var sprint_active: bool = false

@onready var _shoot_button: Button = get_node_or_null("ShootButton") as Button
@onready var _pass_button: Button = get_node_or_null("PassButton") as Button
@onready var _switch_button: Button = get_node_or_null("SwitchButton") as Button

var _active: bool = false
var _center: Vector2 = Vector2.ZERO
var _knob: Vector2 = Vector2.ZERO
var _touch_index: int = -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _shoot_button != null:
		_shoot_button.button_down.connect(_on_shoot_button_down)
		_shoot_button.button_up.connect(_on_shoot_button_up)
	if _pass_button != null:
		_pass_button.button_down.connect(_on_pass_button_down)
		_pass_button.button_up.connect(_on_pass_button_up)
	if _switch_button != null:
		_switch_button.pressed.connect(_on_switch_button_pressed)
	resized.connect(queue_redraw)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_press(event.position, event.pressed, event.index)
	elif event is InputEventScreenDrag:
		if _active and (_touch_index < 0 or event.index == _touch_index):
			_set_knob(event.position)
	elif event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		_handle_press(event.position, event.pressed, -1)
	elif event is InputEventMouseMotion:
		if not _active:
			return
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			return
		if event.position.x > size.x * 0.55:
			return
		_set_knob(event.position)
	else:
		return
	accept_event()


func _draw() -> void:
	var center := _center if _active else _rest_center()
	var alpha := 0.42 if _active else 0.26
	draw_circle(center, stick_radius, Color(1.0, 1.0, 1.0, alpha * 0.4))
	draw_arc(center, stick_radius, 0.0, TAU, 64, Color(1.0, 1.0, 1.0, alpha + 0.16), 4.0, true)
	var knob := _knob if _active else center
	draw_circle(knob, knob_radius, Color(1.0, 1.0, 1.0, alpha + 0.22))


func _rest_center() -> Vector2:
	return Vector2(stick_radius + edge_margin, size.y - stick_radius - edge_margin)


func _handle_press(position: Vector2, pressed: bool, index: int) -> void:
	if pressed:
		if _active:
			return
		if position.x > size.x * 0.55:
			return
		_active = true
		stick_active = true
		sprint_active = false
		_touch_index = index
		_center = position
		_knob = position
		move_vector = Vector2.ZERO
		queue_redraw()
		return
	if not _active:
		return
	if index >= 0 and _touch_index >= 0 and index != _touch_index:
		return
	_release()


func _set_knob(position: Vector2) -> void:
	var delta := position - _center
	if delta.length() > stick_radius:
		delta = delta.normalized() * stick_radius
	_knob = _center + delta
	move_vector = delta / stick_radius
	sprint_active = move_vector.length() > sprint_threshold
	queue_redraw()


func _release() -> void:
	_active = false
	stick_active = false
	sprint_active = false
	_touch_index = -1
	move_vector = Vector2.ZERO
	queue_redraw()


func _on_shoot_button_down() -> void:
	shoot_down = true
	shoot_pressed.emit()


func _on_shoot_button_up() -> void:
	shoot_down = false
	shoot_released.emit()


func _on_pass_button_down() -> void:
	pass_down = true
	pass_pressed.emit()


func _on_pass_button_up() -> void:
	pass_down = false


func _on_switch_button_pressed() -> void:
	switch_pressed.emit()
