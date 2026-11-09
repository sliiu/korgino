# 提供商图标（2026-11-05）

对着现在的品牌标，把 `Assets/ProviderIcons` 和设置里每一行用的预设 id 对了一遍。

## 改了什么

阶跃星辰用的是旧的阶梯形。现在的标是圆里一排方块，单色，跟着文字颜色走，深色浅色都能看见。

「Anthropic 兼容」画的是 Claude 的星标。这一档的名字是 Anthropic，换成 Anthropic 的字标，同样跟着文字颜色。名字里带 Claude、自己又没有图标的，仍用那颗星。

混元是一版糊掉的圆，换成现在的彩色标。Azure 朗读的预设 id 是 `azure`，图只挂在 `azure-openai` 上，行上就落到字母 M。补了 `azure`，和 Azure OpenAI 同一枚。

Kimi、零一万物的主体是黑色，旁边一点蓝或一点绿。深色界面里黑的消失，只剩那个点。深色下把黑墨改成白，彩色点留下。Kimi / Moonshot 继续用 Kimi 的标：列表里的名字是 Kimi，不是 Moonshot 公司的螺旋。

千问同传、OpenAI 同传加进去之后，行上用的 id 是 `qwen-live`、`openai-live`，对不上图标。行上改用它关联的那家翻译预设，所以千问同传是通义的标，OpenAI 同传是 OpenAI 的标。

## 没改

通义、DeepSeek、Gemini、智谱、豆包这些和现在的彩色标对得上。

## 第二轮

深色界面里看不清的不止黑墨。DeepInfra 的深蓝描边、Fireworks 的深紫、Cohere 的深绿也几乎消失。深色版本的规则改成：亮度低于 0.13 的像素占四成以上，就做一张深色用的图。黑和灰改成白；有颜色的往白里混，混到亮度 0.2（在 #1E1E1E 上约 3:1），色相不变。很艳的颜色不动，通义的蓝本来就看得清。

内置翻译换上品牌图：Google（免费、Cloud）、DeepL、微软、百度。截图识别的百度、腾讯、Google Vision、Azure 也一样，不再是字母。朗读的 ElevenLabs、Google 有了图。DeepL 和 ElevenLabs 是单色，跟着文字颜色走。

有道、彩云、Deepgram 在 Lobe Icons 里没有，仍是字母或系统符号。
