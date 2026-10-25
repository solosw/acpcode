import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/ide/markdown/markdown_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('anchors are GitHub\'s, other scripts kept, repeats numbered', () {
    expect(markdownSlug('Getting Started!'), 'getting-started');
    expect(markdownSlug('`code` & more_things'), 'code--more_things');
    expect(markdownSlug('核心架构（必须遵守）'), '核心架构必须遵守');
    final controller = MarkdownController(
      text: '# Usage\n\n## Usage\n\ntext\n\n### `Usage`\n\n# snake_case **x**',
    );
    expect(markdownHeading(controller, 'usage'), 0);
    expect(markdownHeading(controller, 'usage-1'), 2);
    expect(markdownHeading(controller, 'usage-2'), 6);
    expect(markdownHeading(controller, 'Usage'), 0);
    expect(markdownHeading(controller, 'snake_case-x'), 8);
    expect(markdownHeading(controller, 'nope'), isNull);
  });

  test('an anchor with a lone % is looked up as it is, not thrown on', () {
    final controller = MarkdownController(text: '# 100% done\n\n# Rate %d');
    expect(markdownHeading(controller, '100%'), isNull);
    expect(markdownHeading(controller, '100% done'), 0);
    expect(markdownHeading(controller, 'Rate %d'), 2);
  });

  test('link definitions apply to the whole document', () {
    final controller = MarkdownController(
      text: 'See [docs][d].\n\n[d]: https://dart.dev',
    );
    final link = controller
        .inlinesOf(0)
        .firstWhere((run) => run.kind == MdInlineKind.link);
    expect(link.href, 'https://dart.dev');
  });

  group('links', () {
    const doc = '/project/docs/guide.md';
    MarkdownLinkTarget? link(String href, [p.Context? context]) =>
        resolveMarkdownLink(href, doc, context ?? p.posix);

    test('anchors, web and mail', () {
      expect((link('#My%20Part') as MarkdownAnchorLink).anchor, 'My Part');
      expect((link('https://a.b/c') as MarkdownExternalLink).uri.host, 'a.b');
      expect(link('mailto:a@b.c'), isA<MarkdownExternalLink>());
      expect(link('vscode://open'), isNull);
      expect(link(''), isNull);
    });

    test('files, beside the document or absolute, with their fragment', () {
      final relative = link('../README.md#Usage') as MarkdownFileLink;
      expect(relative.path, '/project/README.md');
      expect(relative.fragment, 'Usage');
      final spaced = link('img/a%20b.png') as MarkdownFileLink;
      expect(spaced.path, '/project/docs/img/a b.png');
      expect(spaced.fragment, isNull);
      expect((link('/etc/hosts') as MarkdownFileLink).path, '/etc/hosts');
      expect((link('file:///tmp/x.md') as MarkdownFileLink).path, '/tmp/x.md');
    });

    test('a Windows path is no scheme', () {
      final windows = p.Context(style: p.Style.windows);
      final target = resolveMarkdownLink(
        r'C:\notes\a.md',
        r'C:\project\guide.md',
        windows,
      );
      expect((target as MarkdownFileLink).path, r'C:\notes\a.md');
      final relative = resolveMarkdownLink(
        'sub/b.md',
        r'C:\project\guide.md',
        windows,
      );
      expect((relative as MarkdownFileLink).path, r'C:\project\sub\b.md');
    });

    test('images: web ones by address, others by path', () {
      expect(
        resolveMarkdownImage('https://x.y/a.png', doc, p.posix)?.url,
        Uri.parse('https://x.y/a.png'),
      );
      expect(
        resolveMarkdownImage('a.png', doc, p.posix)?.path,
        '/project/docs/a.png',
      );
      expect(resolveMarkdownImage('mailto:a@b.c', doc, p.posix), isNull);
    });
  });
}
