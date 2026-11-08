@tool
extends EditorPlugin
## 仅编辑器使用的辅助线。所有可调数值仍保存在节点或 FogSettings 资源中。

const GIZMO_SCRIPT = preload("res://addons/fog_gizmos/fog_gizmo.gd")
var _gizmo: EditorNode3DGizmoPlugin
var _elapsed := 0.0


func _enter_tree() -> void:
	_gizmo = GIZMO_SCRIPT.new()
	add_node_3d_gizmo_plugin(_gizmo)
	# 显式测试开关，仅供命令行验收编辑器 @tool 路径；普通编辑器会话不会加载测试。
	if "--fog-editor-smoke" in OS.get_cmdline_user_args():
		_run_editor_smoke.call_deferred()


func _run_editor_smoke() -> void:
	var smoke = load("res://tests/editor_smoke.gd").new()
	await smoke.run(self)


func _exit_tree() -> void:
	set_process(false)
	remove_node_3d_gizmo_plugin(_gizmo)
	_gizmo = null


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.15:
		return
	_elapsed = 0.0
	# 足迹节点没有逐属性 setter；只刷新选中节点，既能实时跟随 Inspector，又不遍历整场景。
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is InteractiveFogField or node is FogObstacle3D or node is FogInteractor3D:
			node.update_gizmos()
