const test = require('node:test');
const assert = require('node:assert/strict');
const { Application } = require('../dist/cjs/Application/Application.js');
const { UIElementCreationMode } = require('../dist/cjs/UI/UIConfigurationTypes.js');

function element() {
    return { children: [], style: {}, classList: { add() {}, remove() {} },
        appendChild(child) { this.children.push(child); return child; },
        setAttribute() {}, setAttributeNS() {}, addEventListener() {} };
}

test('Application exposes the actual toolbar used by player extensions', (t) => {
    const savedDocument = Object.getOwnPropertyDescriptor(globalThis, 'document');
    const savedNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
    t.after(() => {
        if (savedDocument) Object.defineProperty(globalThis, 'document', savedDocument); else delete globalThis.document;
        if (savedNavigator) Object.defineProperty(globalThis, 'navigator', savedNavigator); else delete globalThis.navigator;
    });
    Object.defineProperty(globalThis, 'document', { configurable: true, value: { createElement: element,
        createElementNS: element, addEventListener() {} } });
    Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { userAgent: 'Desktop', vendor: '' } });
    const application = Object.create(Application.prototype);
    application._options = { xrControlsConfig: { creationMode: UIElementCreationMode.Disable } };
    application._uiFeatureElement = element();
    application._rootElement = element();
    application.createButtons();
    assert.ok(application.controls, 'toolbar must be assigned before player bootstrap uses it');
    assert.equal(application.controls.rootElement, application.uiFeaturesElement.children[0]);
    assert.equal(application.controls.rootElement.children.length, 3);
});
