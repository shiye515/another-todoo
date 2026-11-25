# 图像 AI 量化提示词指南

面向「用图像生成/编辑模型产出适合 TodooCard 电子墨水屏的图片」的提示词编写指南。
目标设备：**528×792 六色电子墨水屏**（黑 / 白 / 黄 / 红 / 蓝 / 绿），无灰阶、无渐变，靠抖动（dithering）表现层次。

## 1. 先记住硬件约束（写提示词的前提）

| 约束 | 含义 | 提示词里的对应写法 |
| --- | --- | --- |
| 6 色调色板 | 只有黑白黄红蓝绿，没有灰、粉、紫 | `six-color palette: black, white, yellow, red, blue, green only` |
| 无渐变 | 渐变会被抖动成噪点 | `flat solid colors, no gradients, no shading` |
| 分辨率 528×792（2:3 竖版） | 细节会被吃掉 | `portrait 2:3 composition, bold shapes` |
| 远距离观看（1–2m） | 文字必须大、笔画粗 | `large bold legible text, thick strokes` |
| 抖动质感 | 照片类需 dithering 才自然 | `pixel dithered style / halftone texture` |

## 2. 提示词四段式结构

```
[主体内容] + [构图/画幅] + [调色板与风格约束] + [排除项(negative)]
```

1. **主体**：要画什么（一张海边日落海报 / 菜单价目表 / 二维码卡片）。
2. **构图/画幅**：`portrait 2:3`、`centered layout`、`generous margins`。
3. **调色板与风格**：六色、平涂、粗描边、像素/抖动风。
4. **排除项**：渐变、阴影、灰阶、细线、小字、水印。

## 3. 可复制模板

### 3.1 照片 → 六色抖动风（导入 App 前预处理）

```text
Convert this photo into a six-color e-ink artwork: palette strictly limited to
black, white, yellow, red, blue and green. Flat solid color regions with bold
outlines, pixel-dithered halftone texture for tone transitions, portrait 2:3
composition, high contrast, no gradients, no gray, no shadows.
```

中文版：

```text
把这张照片转换为六色电子墨水屏插画：调色板严格限定为黑、白、黄、红、蓝、绿；
色块平涂、粗描边，明暗过渡用像素抖动/网点质感；竖版 2:3 构图、高对比；
不要渐变、不要灰色、不要阴影。
```

### 3.2 极简海报 / 标语牌

```text
Minimal poster for TodooCard e-ink display, portrait 2:3: a large sun icon over
simple geometric waves, big bold headline text "HELLO SUMMER", flat six-color
palette (black, white, yellow, red, blue, green), thick strokes, generous
whitespace, no gradients, no small text, no watermark.
```

### 3.3 菜单 / 价目表 / 二维码卡片

```text
Simple price list card, portrait 2:3: white background, bold black title,
yellow highlight boxes for prices, red accents for badges, large sans-serif
text (min 24px equivalent stroke), flat colors only, six-color palette
(black/white/yellow/red/blue/green), high contrast, no photos, no gradients,
no thin lines.
```

> 二维码建议单独生成后合成：对二维码区域**不要**加抖动，六色屏上纯黑/纯白的码最易识别。

## 4. 关键词速查

**想要的效果 → 加这些词**

- 像素/抖动质感：`pixel art`、`dithered halftone`、`1-bit dithered shading`、`retro Macintosh dithering`
- 平涂硬边：`flat colors`、`bold outlines`、`hard edges`、`no anti-aliasing`
- 高可读性：`large bold text`、`thick strokes`、`high contrast`、`legible from distance`
- 竖版构图：`portrait 2:3`、`vertical layout`、`centered subject`

**必须排除（negative）**

```text
gradients, shadows, gray tones, pastel colors, metallic, glossy, thin lines,
small text, cursive fonts, photo realism, blur, watermark, logo
```

## 5. 推荐工作流

1. **生成**：让模型按 2:3 出图（如 1024×1536），宁大勿小。
2. **导入 App**：拖入「添加图片」（⌘O），裁剪到 528×792 成品。
3. **对比量化**：详情区四个变体卡（标准量化 / Floyd–Steinberg / Atkinson / Ostromoukhov）逐一查看——
   - 图形、文字、Logo → **标准量化**（边缘锐利）
   - 照片、渐变天空 → **Floyd–Steinberg** 或 **Ostromoukhov**（过渡自然、纹理均匀）
   - 明暗对比强烈 → **Atkinson**（对比度更高）
4. **选中并发送**：点卡片选中 → 「发送到设备」。
5. 效果不满意 → 用「重新生成 / 重新量化全部」，或回到第 1 步改提示词（通常是去掉细节、放大主体）。

## 6. 常见翻车与修正

| 现象 | 原因 | 提示词修正 |
| --- | --- | --- |
| 画面全是噪点 | 原图渐变/柔和光太多 | 加 `flat colors, no gradients`，主体放大 |
| 文字糊成一团 | 字太小/太细 | 加 `large bold text, thick strokes`，文字控制在 5 个词内 |
| 出现调色板外的颜色 | 模型没守约束 | 显式列举六色并加 `strictly limited palette`；导入后仍以 App 内量化结果为准 |
| 细线消失/断裂 | 笔画低于像素宽度 | `bold outlines, avoid thin lines` |
| 二维码扫不出 | 抖动破坏码点 | 二维码区域不抖动，纯黑白；留足静区 |
