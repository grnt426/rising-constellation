// Renders engine values/results into display strings. Pure: every
// locale-dependent primitive is injected via `f`, so the module works both
// under node tests (with stub formatters) and in components (with the real
// utils/format + i18n bindings):
//
//   f = {
//     int(n)            -> "13,400"
//     num(n)            -> "0.5"      (short float, 1 decimal)
//     dur(seconds)      -> "6h 12min" (utils/format formatDuration)
//     time(ms)          -> "18:10" / "Fri 18:10" / "Aug 2 18:10"
//     t(key, params)    -> i18n translate (calc.* keys)
//   }
//
// Returns { text, detail } — text is the primary result line, detail an
// optional secondary line the UI renders smaller.

const short = (f, v) => (Number.isInteger(v) || Math.abs(v) >= 100 ? f.int(v) : f.num(v));

const resSuffix = (f, res) => (res ? ` ${f.t(`calc.res_short.${res}`)}` : '');

const pausedSuffix = (f, result) => (result.paused ? ` ${f.t('calc.result.paused')}` : '');

export function formatValue(result, f) {
  switch (result.k) {
    case 'scalar':
      return { text: short(f, result.v) + resSuffix(f, result.res) };

    case 'rate': {
      const sign = result.vPerHour >= 0 ? '+' : '';
      return {
        text: `${sign}${short(f, result.vPerHour)}/h${resSuffix(f, result.res)}`,
        detail: `${sign}${short(f, result.vPerHour * 24)}/${f.t('calc.result.day_abbr')}`,
      };
    }

    case 'dur':
      return { text: f.dur(result.s) };

    case 'dt':
      return { text: f.time(result.ms) };

    case 'eta': {
      if (result.reached) return { text: f.t('calc.result.reached_now') + pausedSuffix(f, result) };
      if (result.never) {
        return {
          text: f.t('calc.result.never'),
          detail: f.t('calc.result.missing', { amount: f.int(result.need) + resSuffix(f, result.res) }),
        };
      }
      return {
        text: `${f.dur(result.s)} · ${f.time(result.when)}${pausedSuffix(f, result)}`,
        detail: f.t('calc.result.missing', { amount: f.int(result.need) + resSuffix(f, result.res) }),
      };
    }

    case 'afford': {
      if (result.ok) return { text: f.t('calc.result.afford_yes') + pausedSuffix(f, result) };
      if (result.never) {
        return {
          text: f.t('calc.result.afford_never', { amount: f.int(result.shortfall) + resSuffix(f, result.res) }),
        };
      }
      return {
        text: f.t('calc.result.afford_in', { duration: f.dur(result.s) }) + pausedSuffix(f, result),
        detail: `${f.time(result.when)} · ${f.t('calc.result.missing', { amount: f.int(result.shortfall) + resSuffix(f, result.res) })}`,
      };
    }

    case 'projection':
      return {
        text: short(f, result.v) + resSuffix(f, result.res) + pausedSuffix(f, result),
        detail: f.time(result.when),
      };

    case 'snapshot': {
      const parts = ['credit', 'technology', 'ideology']
        .map((res) => `${f.int(result.resources[res])}${resSuffix(f, res)}`);
      return {
        text: parts.join(' · ') + pausedSuffix(f, result),
        detail: f.time(result.when),
      };
    }

    default:
      return { text: '?' };
  }
}

// CalcError -> human message. Error codes map onto calc.error.* keys; the
// data payload provides interpolation params where useful.
export function formatError(error, f) {
  const code = (error && error.code) || 'PARSE';
  switch (code) {
    case 'MIXED_RESOURCES':
      return f.t('calc.error.mixed_resources', {
        a: f.t(`calc.res_short.${error.data.a}`),
        b: f.t(`calc.res_short.${error.data.b}`),
      });
    case 'UNKNOWN_NAME':
      return f.t('calc.error.unknown_name', { name: error.data.name });
    case 'NAME_TAKEN':
      return f.t('calc.error.name_taken', { name: error.data.name });
    case 'NEED_RESOURCE':
      return f.t('calc.error.need_resource');
    case 'PAST_TIME':
      return f.t('calc.error.past_time');
    case 'DIV_ZERO':
      return f.t('calc.error.div_zero');
    case 'NO_DATA':
      return f.t('calc.error.no_data');
    case 'BAD_OP':
      return f.t('calc.error.bad_op');
    case 'PARSE':
    default:
      return f.t('calc.error.parse');
  }
}

export default { formatValue, formatError };
