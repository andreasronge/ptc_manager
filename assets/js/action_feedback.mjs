// LiveView owns request completion; an acknowledgement is not a success message.
// Keep the busy announcement until every overlapping button/form request settles.
export function installActionFeedback(events, document) {
  const busy = new Map()
  let pending = 0
  let generation = 0
  const announce = text => {
    const status = document.getElementById('action-feedback')
    if (!status) return
    if (status.textContent !== text) status.textContent = text
    if (text) status.setAttribute('class', 'is-pending')
    else status.removeAttribute('class')
  }

  const restore = (target, state) => {
    if (state.previous === null) target.removeAttribute('aria-busy')
    else target.setAttribute('aria-busy', state.previous)
  }

  // A live redirect replaces the view; abandoned requests must not keep the next
  // page busy. Patches stay in the same view and retain their pending requests.
  events.addEventListener('phx:page-loading-stop', ({detail}) => {
    if (detail.kind !== 'redirect') return
    generation++
    for (const [target, state] of busy) restore(target, state)
    busy.clear()
    pending = 0
    announce('')
  })

  events.addEventListener('phx:push', ({target, detail}) => {
    const action = (detail.eventType === 'click' && target.tagName === 'BUTTON') ||
      (detail.eventType === 'submit' && target.tagName === 'FORM')
    if (!action) return

    const startedIn = generation
    const state = busy.get(target) || {count: 0, previous: target.getAttribute('aria-busy')}
    state.count++
    busy.set(target, state)
    target.setAttribute('aria-busy', 'true')
    pending++
    announce('Working…')

    detail.loadingComplete.then(() => {
      if (startedIn !== generation) return
      if (--state.count === 0) {
        restore(target, state)
        busy.delete(target)
      }
      if (--pending === 0) announce('')
    })
  })
}
