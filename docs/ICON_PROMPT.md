# MC Harbor 图标记录

## 2026-10-25 当前正式资产

按用户最新要求，App 图标改为透明底的浅银白折面 h，不烘焙黑底、圆角方框、外描边或投影。保留既有标准标志的比例与折面，由 Sources/Brand.swift 的原生矢量路径绘制；tools/RenderBrand.swift 生成 1024×1024 透明 Icon.png，h 高度 700px，四周留白。macOS 自行决定图标的系统容器与边缘呈现。

App / Finder / Dock 使用同一份 HarborMark.icns，Info.plist 构建号 142。旧 AppIcon.icns 从正式包移除，不调用运行时图标覆盖，也不设置 Finder 自定义图标。侧栏和欢迎页继续使用无底 h。以下黑底图像生成记录仅用于说明设计来源，已被本次透明矢量资产取代。

## 已取代的黑底生成记录

2026-10-25 · 内置 imagegen · 依据用户提供的 Unknown.png 重制。

正式资产：`Assets/Brand/Icon.png`。黑色磨砂圆角底、浅银白折面 h，整体占画布约 80%，标志保持参考比例。PNG 原字节保留；构建只做 macOS 所需尺寸缩放并封装为 ICNS。侧栏 / 欢迎页使用标准 h 的原生矢量无底版本（Sources/Brand.swift），预览导出为 Assets/Brand/Mark.png；SF Pro 字标为 MC Harbor。完整黑底图标用于 App / Dock。AppKit 运行期间不再替换图标，Dock 与 Finder 使用同一份 AppIcon.icns。

实际提示词：

```text
Use case: logo-brand. Refine the provided reference into the finished production macOS app icon for MC harbor. The reference is the authoritative design: keep its BLACK/graphite frosted matte rounded-square tile, its overall scale and transparent outer padding, and especially the distinctive pale folded architectural lowercase h monogram. Preserve the tall left upright with its diagonal-cut top, the right upright and the broad angular folded bridge with a flat planar top, subtle triangular underside and clean negative-space arch. Do not turn the bridge into a wavy ribbon and do not add a separate upper-right vertical stroke. Keep the mark at the reference's relative size, approximately 58–60 percent of the tile width. Keep the tile about 80 percent of the total square canvas width so the whole icon has restrained macOS Dock occupancy. Front-on view; exquisitely simple, precise, softly frosted off-white / silver mark with gentle neutral diffuse shading. Quiet matte texture, no noisy distress. No Liquid Glass rim, no transparent border, no rainbow, no colored highlight, no glossy bevel, no bright outline, no glow, no extra text, no Minecraft cube, no scene. Outside the single tile must be clean transparent alpha, with no black rectangle, white fringe or stray pixels. Preserve the design, improve only edge precision, finish and optical balance.
```

输入参考：用户下载目录中的 `Unknown.png`。生成模式为内置 imagegen，透明背景开启。最终文件源自本会话 generated_images 中的 exec-c214059e-e264-4fcf-bc7f-8d5f1cfeab03.png，复制到项目后参与交付。
