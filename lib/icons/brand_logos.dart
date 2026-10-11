import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The logos of models and their makers, in one color: Iconify's (Simple
/// Icons, theSVG, Remix Icon), kept in `assets/model_icons/`, drawn in the
/// color of the text around them.
abstract final class BrandLogos {
  /// Each by its file's name, as it is listed (and searched) in the icon
  /// picker: its maker's name.
  static const names = {
    'claude': 'Claude',
    'claudecode': 'Claude Code',
    'anthropic': 'Anthropic',
    'openai': 'OpenAI',
    'gemini': 'Gemini',
    'google': 'Google',
    'deepseek': 'DeepSeek',
    'qwen': 'Qwen',
    'zhipu': 'Zhipu GLM',
    'kimi': 'Kimi',
    'moonshot': 'Moonshot AI',
    'minimax': 'MiniMax',
    'doubao': 'Doubao',
    'bytedance': 'ByteDance',
    'volcengine': 'Volcengine',
    'hunyuan': 'Hunyuan',
    'wenxin': 'ERNIE',
    'stepfun': 'StepFun',
    'baichuan': 'Baichuan',
    'yi': 'Yi',
    'xai': 'xAI Grok',
    'mistral': 'Mistral AI',
    'meta': 'Meta Llama',
    'microsoft': 'Microsoft',
    'nvidia': 'NVIDIA',
    'perplexity': 'Perplexity',
    'githubcopilot': 'GitHub Copilot',
    'openrouter': 'OpenRouter',
    'siliconflow': 'SiliconFlow',
    'together': 'Together AI',
    'fireworks': 'Fireworks AI',
    'huggingface': 'Hugging Face',
    'ollama': 'Ollama',
    'lmstudio': 'LM Studio',
    'azure': 'Azure AI',
    'bedrock': 'Amazon Bedrock',
    'vertexai': 'Vertex AI',
    'cloudflare': 'Cloudflare',
    'vercel': 'Vercel',
  };

  static String asset(String name) => 'assets/model_icons/$name.svg';
}

/// Logo [name] of [BrandLogos] in a square of [size], in [color].
class BrandLogo extends StatelessWidget {
  const BrandLogo(this.name, {super.key, required this.size, this.color});

  final String name;
  final double size;

  /// The text's when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? DefaultTextStyle.of(context).style.color;
    return SvgPicture.asset(
      BrandLogos.asset(name),
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
