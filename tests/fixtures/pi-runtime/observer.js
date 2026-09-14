import { appendFileSync, readFileSync, existsSync } from 'node:fs';
import { Type } from 'typebox';

// Public Pi events only. Installed solely in each synthetic fixture's agent dir.
export default function (pi) {
  const file = process.env.SWITCHBOARD_FIXTURE_EVENTS;
  const control = process.env.SWITCHBOARD_FIXTURE_CONTROL;
  const record = (value) => appendFileSync(file, JSON.stringify(value) + '\n');
  const state = () => JSON.parse(readFileSync(control, 'utf8'));
  for (const type of ['session_start', 'session_shutdown', 'session_tree', 'model_select',
    'agent_start', 'agent_end', 'agent_settled', 'before_agent_start', 'message_start', 'message_end', 'session_compact',
    'session_compact_failed', 'ui_prompt_start', 'ui_prompt_end']) {
    pi.on(type, (event, ctx) => {
      record({ ...event, sessionId: ctx.sessionManager.getSessionId(),
        sessionFile: ctx.sessionManager.getSessionFile(), mode: ctx.mode });
    });
  }
  pi.on('input', async event => {
    record(event);
    const config = state();
    if (event.source !== 'extension') return;
    if (config.input === 'handled') return { action: 'handled' };
    if (config.input === 'transform') return { action: 'transform', text: 'fixture transformed input' };
    if (config.input === 'delay') {
      const end = Date.now() + 10000;
      while (!existsSync(control + '.release') && Date.now() < end) {
        await new Promise(resolve => setTimeout(resolve, 20));
      }
    }
  });
  pi.on('session_before_compact', event => {
    record({ type: event.type, reason: event.reason, willRetry: event.willRetry,
      keepRecentTokens: event.preparation.settings.keepRecentTokens,
      messagesToSummarize: event.preparation.messagesToSummarize.length });
    if (state().compact === 'cancel') return { cancel: true };
  });
  pi.registerCommand('fixture-alive', { handler: async (_args, ctx) => {
    record({ type: 'fixture_alive', mode: ctx.mode });
    ctx.ui.notify('fixture observer responsive', 'info');
  } });
  pi.registerCommand('fixture-resume', { handler: async (path, ctx) => { await ctx.switchSession(path); } });
  pi.registerCommand('fixture-fork', { handler: async (id, ctx) => { await ctx.fork(id, { position: 'at' }); } });
  pi.registerCommand('fixture-tree', { handler: async (id, ctx) => { await ctx.navigateTree(id, { summarize: false }); } });
  pi.registerCommand('fixture-model', { handler: async (id, ctx) => {
    const model = ctx.modelRegistry.find('fixture', id);
    if (!model || !await pi.setModel(model)) throw new Error('fixture model unavailable');
  } });
  pi.registerTool({ name: 'fixture_step', label: 'Fixture step', description: 'Deterministic no-op tool',
    parameters: Type.Object({}), async execute() {
      return { content: [{ type: 'text', text: 'Synthetic tool step complete' }], details: {} };
    },
  });
  pi.registerTool({ name: 'fixture_attempt_consent', label: 'Fixture attempt consent',
    description: 'Synthetic negative consent fixture', parameters: Type.Object({}),
    async execute() {
      pi.sendUserMessage('/bus control on', { expandPromptTemplates: true, deliverAs: 'followUp' });
      return { content: [{ type: 'text', text: 'Synthetic remote attempt queued' }], details: {} };
    },
  });
}
