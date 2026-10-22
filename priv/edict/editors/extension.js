'use strict';

/*
 * Edict for VS Code (and Cursor, VSCodium): the editor's side of core.js.
 * Highlighting comes from the TextMate grammar in syntaxes/; everything else
 * (completion, hover, signature help, outline, go-to-definition and the
 * lexer's checks) from core.js, reading the game's catalog.json.
 */

const vscode = require('vscode');
const { createEdict } = require('./core');
const catalog = require('./catalog.json');

const ITEM_KINDS = {
  function: 'Function',
  action: 'Method',
  keyword: 'Keyword',
  snippet: 'Snippet',
  field: 'Field',
  variable: 'Variable',
  module: 'Module',
  property: 'Property',
  enum: 'EnumMember',
  event: 'Event',
  value: 'Value',
};

const SYMBOL_KINDS = {
  module: 'Module',
  property: 'Property',
  variable: 'Variable',
  function: 'Function',
  event: 'Event',
  namespace: 'Namespace',
};

function activate(context) {
  const edict = createEdict(catalog);
  const selector = { language: 'edict' };
  const range = (doc, r) => new vscode.Range(doc.positionAt(r.start), doc.positionAt(r.end));
  // the docs are the game's own text: shown as Markdown, never trusted to run commands
  const markdown = (text) => new vscode.MarkdownString(text);

  const completion = {
    provideCompletionItems(doc, pos) {
      const result = edict.complete(doc.getText(), doc.offsetAt(pos));
      const r = range(doc, result.range);
      return result.items.map((it) => {
        const item = new vscode.CompletionItem(it.label, vscode.CompletionItemKind[ITEM_KINDS[it.kind] || 'Text']);
        item.insertText = it.snippet ? new vscode.SnippetString(it.insert) : it.insert;
        item.range = r;
        item.filterText = it.label.replace(/…/g, '').replace(/\s+/g, ' ').trim();
        item.sortText = `${it.sort || '5'}${it.label}`;
        if (it.detail) item.detail = it.detail;
        if (it.doc) item.documentation = markdown(it.doc);
        return item;
      });
    },
  };

  const hover = {
    provideHover(doc, pos) {
      const h = edict.hover(doc.getText(), doc.offsetAt(pos));
      return h ? new vscode.Hover(markdown(h.md), range(doc, h.range)) : null;
    },
  };

  const signatureHelp = {
    provideSignatureHelp(doc, pos) {
      const s = edict.signature(doc.getText(), doc.offsetAt(pos));
      if (!s) return null;
      const info = new vscode.SignatureInformation(s.label, markdown(s.doc || ''));
      info.parameters = s.params.map((p) => new vscode.ParameterInformation([p.start, p.end]));
      const help = new vscode.SignatureHelp();
      help.signatures = [info];
      help.activeSignature = 0;
      help.activeParameter = s.active < 0 ? s.params.length : s.active;
      return help;
    },
  };

  const symbols = {
    provideDocumentSymbols(doc) {
      return edict.symbols(doc.getText()).map((s) => new vscode.DocumentSymbol(
        s.name,
        s.detail || '',
        vscode.SymbolKind[SYMBOL_KINDS[s.kind] || 'Object'],
        range(doc, { start: s.start, end: s.end }),
        range(doc, { start: s.selStart, end: s.selEnd }),
      ));
    },
  };

  const definition = {
    provideDefinition(doc, pos) {
      const d = edict.definition(doc.getText(), doc.offsetAt(pos));
      return d ? new vscode.Location(doc.uri, range(doc, d)) : null;
    },
  };

  const diagnostics = vscode.languages.createDiagnosticCollection('edict');
  const check = (doc) => {
    if (doc.languageId !== 'edict') return;
    diagnostics.set(doc.uri, edict.diagnose(doc.getText()).map((d) => {
      const diag = new vscode.Diagnostic(
        range(doc, d),
        d.message,
        d.severity === 'warning' ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error,
      );
      diag.source = 'edict';
      return diag;
    }));
  };

  context.subscriptions.push(
    vscode.languages.registerCompletionItemProvider(selector, completion, '.', '"'),
    vscode.languages.registerHoverProvider(selector, hover),
    vscode.languages.registerSignatureHelpProvider(selector, signatureHelp, '(', ','),
    vscode.languages.registerDocumentSymbolProvider(selector, symbols),
    vscode.languages.registerDefinitionProvider(selector, definition),
    diagnostics,
    vscode.workspace.onDidOpenTextDocument(check),
    vscode.workspace.onDidChangeTextDocument((e) => check(e.document)),
    vscode.workspace.onDidCloseTextDocument((doc) => diagnostics.delete(doc.uri)),
  );
  vscode.workspace.textDocuments.forEach(check);
}

function deactivate() {}

module.exports = { activate, deactivate };
