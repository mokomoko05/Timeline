# 标题栏原生拖动越界

前几轮的拖动约束只覆盖了过滤器自己认出来的按下：标题栏里命中可拖视图、或内容里 `mouseDownCanMoveWindow` 为真的视图。其余按下照常交给 AppKit。隐藏窗口里实测：终端这类普通透明标题栏，标题栏空白命中的是 `NSThemeFrame`，它的 `mouseDownCanMoveWindow` 为假；透明全尺寸标题栏下，没接住点击也不声明可拖的内容会把按下交回主题框架。两种情况 AppKit 都会在按下时同步调用 `performDrag(with:)`，默认实现把整段拖动交给窗口服务器，不经过 `constrainFrameRect`，于是 Board、笔记、终端窗口能拖出屏幕边缘，和应用自己的约束交替时还会抖动。

`ScreenBoundWindow` 与 `QuietPanel` 现在覆盖 `performDrag(with:)`：鼠标按下引起的原生拖动不再交给窗口服务器，而是记下起点，由随后的拖动事件走和标题栏拖动相同的取整、`constrainFrameRect` 路径；全屏或非按下事件仍调用系统实现。过滤器原有的判定、双击和控件放行不变。

新回归在隐藏窗口里通过真实的 `sendEvent` → 主题框架 → `performDrag` 链路验证两种标题栏，向四个边缘拖动都留在可见区域内，且没有调用系统拖动；把接管改回系统实现时该用例失败。测试只注入指针采样值，不移动真实鼠标，不能替代前台物理拖动的手感验证。
