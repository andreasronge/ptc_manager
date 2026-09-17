import test from 'node:test'
import assert from 'node:assert/strict'
import {installActionFeedback} from '../../assets/js/action_feedback.mjs'

function element(tagName = 'BUTTON') {
  const attrs = new Map()
  return {tagName, textContent: '', setAttribute: (k,v) => attrs.set(k,v),
    getAttribute: k => attrs.get(k) ?? null, removeAttribute: k => attrs.delete(k)}
}
function setup() {
  const handlers = {}
  const status = element('DIV')
  installActionFeedback({addEventListener: (name, fn) => {handlers[name] = fn}},
    {getElementById: () => status})
  function push(target, eventType = 'click') {
    let complete
    const loadingComplete = new Promise(resolve => {complete = resolve})
    handlers['phx:push']({target, detail: {eventType, loadingComplete}})
    return async () => {complete(); await loadingComplete; await Promise.resolve()}
  }
  return {status, push, navigate: () => handlers['phx:page-loading-stop']({detail: {kind: 'redirect'}})}
}

test('shows pending feedback and restores the button when the response arrives', async () => {
  const {status, push} = setup()
  const button = element()
  const complete = push(button)
  assert.equal(button.getAttribute('aria-busy'), 'true')
  assert.equal(status.textContent, 'Working…')
  await complete()
  assert.equal(button.getAttribute('aria-busy'), null)
  assert.equal(status.textContent, '')
})

test('one completed action does not clear another pending action', async () => {
  const {status, push} = setup()
  const button = element()
  const first = push(button)
  const second = push(button)
  await first()
  assert.equal(button.getAttribute('aria-busy'), 'true')
  assert.equal(status.textContent, 'Working…')
  await second()
  assert.equal(button.getAttribute('aria-busy'), null)
  assert.equal(status.textContent, '')
})

test('form submission is announced once and existing busy attributes are preserved', async () => {
  const {status, push} = setup()
  const form = element('FORM')
  form.setAttribute('aria-busy', 'false')
  const complete = push(form, 'submit')
  assert.equal(form.getAttribute('aria-busy'), 'true')
  await push(element(), 'submit')()
  assert.equal(status.textContent, 'Working…')
  await complete()
  assert.equal(form.getAttribute('aria-busy'), 'false')
})

test('typing and unrelated events do not announce work', async () => {
  const {status, push} = setup()
  await push(element('INPUT'), 'change')()
  await push(element('DIV'), 'hook')()
  assert.equal(status.textContent, '')
})


test('navigation abandons pending feedback without letting an old reply clear new work', async () => {
  const {status, push, navigate} = setup()
  const oldButton = element()
  const oldReply = push(oldButton)
  navigate()
  assert.equal(status.textContent, '')
  assert.equal(oldButton.getAttribute('aria-busy'), null)
  const newReply = push(element())
  await oldReply()
  assert.equal(status.textContent, 'Working…')
  await newReply()
  assert.equal(status.textContent, '')
})
