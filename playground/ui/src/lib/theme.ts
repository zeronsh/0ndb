import { useCallback, useEffect, useState } from 'react'

export type ThemePref = 'light' | 'dark' | 'system'

function read(): ThemePref {
  try {
    const v = localStorage.getItem('ondb-theme')
    if (v === 'light' || v === 'dark' || v === 'system') return v
  } catch {
    return 'system'
  }
  return 'system'
}

function apply(pref: ThemePref) {
  const dark = pref === 'dark' || (pref === 'system' && matchMedia('(prefers-color-scheme: dark)').matches)
  const root = document.documentElement
  root.classList.add('[&_*]:!transition-none')
  root.classList.toggle('dark', dark)
  requestAnimationFrame(() => root.classList.remove('[&_*]:!transition-none'))
}

export function useTheme() {
  const [pref, setPref] = useState<ThemePref>(read)
  useEffect(() => {
    apply(pref)
    try {
      localStorage.setItem('ondb-theme', pref)
    } catch {
      return
    }
    if (pref !== 'system') return
    const mq = matchMedia('(prefers-color-scheme: dark)')
    const on = () => apply('system')
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [pref])
  const cycle = useCallback(() => setPref(p => (p === 'light' ? 'dark' : p === 'dark' ? 'system' : 'light')), [])
  return { pref, setPref, cycle }
}

export function usePersistent<T>(key: string, initial: T) {
  const [value, setValue] = useState<T>(() => {
    try {
      const raw = localStorage.getItem(key)
      return raw == null ? initial : (JSON.parse(raw) as T)
    } catch {
      return initial
    }
  })
  useEffect(() => {
    try {
      localStorage.setItem(key, JSON.stringify(value))
    } catch {
      return
    }
  }, [key, value])
  return [value, setValue] as const
}
