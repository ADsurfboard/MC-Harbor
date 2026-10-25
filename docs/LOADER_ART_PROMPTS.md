# 默认实例图标重绘

使用内置 imagegen 工具，分别生成 7 个真正透明的 PNG。成品位于 `Assets/Loaders/`，不替换实例资源作者的原图标。生成元数据见同目录 `imagegen-provenance.json`。原始输出按生成工具默认保存，项目内已经复制成独立资源。

共同提示词：

> Use case: stylized-concept. Asset type: one high-resolution transparent PNG default mod-loader/game icon for MC Harbor, not an app icon tile. Render ONE isolated object in an orthographic isometric view, top and two faces visible, consistent with a premium graphite anvil render. Crisp precise edges, clean Minecraft-inspired simplified block forms, subtle detailed material, soft neutral studio lighting. Center the object with a 9 percent transparent margin on each side, excellent silhouette at 32 pixels and very sharp at 400 pixels. Genuinely transparent background. No plates, no app tile, no border, no text, no watermark, no glow, no blur, no environment.

各图在共同提示词后增加：

- grass.png: Subject: one classic Minecraft grass block cube. Rich natural ecological green grass top with square little tufts and a restrained fringe cascading over dark warm earth sides, layers of small cubic dirt and stone textures. Familiar Minecraft grass block identity, premium dimensional texture and accurate cubic proportions, no extra plants.
- fabric.png: Subject: a single antique ivory parchment scroll representing Fabric mod loader. Paper unfurled diagonally, two rolled cylinders at opposite ends, gentle warm creamy paper, delicate grain, minimalist blank face, clean sculptural volume, not a book. No decorative markings or writing.
- quilt.png: Subject: one neatly folded small square quilt fabric patchwork representing Quilt mod loader. Four by four sewn square patches in muted plum, lavender, cream, sage, subtle visible stitches and fine textile weave, soft padded thickness, top three-quarter isometric view, precise square silhouette.
- neoforge.png: Subject: one blocky orange fox head emblem representing NeoForge. Recognizable square Minecraft fox face and two pointed block ears, burnt orange and ivory fur, tiny charcoal eyes and nose, only head, no neck or body. Sharp premium 3D voxel sculptural render with subtle fur-like block surface.
- legacyfabric.png: Subject: one short rolled linen scroll bundle representing Legacy Fabric mod loader. Warm sand beige cylindrical linen scroll with an unfurled blank small flap, clean subtly woven texture and simple narrow brown leather tie, isometric viewpoint, one object, unmistakably a parchment/fabric roll.
- cleanroom.png: Subject: one minimalist block-shaped laboratory cleanroom air filter module representing Cleanroom mod loader. Satin ivory rectangular cube, restrained sage-green grille with precisely spaced narrow fins on one front face, clean polished metal and frosted white top panel, no UI, no numbers, no typography. Compact square silhouette.

forge.png 独立提示词：

> Use case: stylized-concept. Asset type: a high-resolution transparent PNG launcher icon for the Forge mod loader, not an app icon tile. Primary request: redraw the reference anvil as a sharp premium 3D Minecraft-inspired iron anvil: familiar large rectangular hornless top block, tapered waist, broad stepped rectangular foot. Orthographic isometric view, top and two side faces visible, precise bevels, dark graphite iron, subtle block texture, excellent legibility at 32 pixels and crisp detailed silhouette at 400 pixels. Center one isolated anvil occupying 82 percent of square canvas. Background genuinely transparent. Soft studio illumination, clean restrained material, Apple-quality product render. No glass plates, no rounded square tile, no border, no typography, no glow, no blur, no environment. The screenshot in conversation is reference only for subject and viewpoint; improve its coarse low-resolution look while retaining recognizable Minecraft anvil identity.
