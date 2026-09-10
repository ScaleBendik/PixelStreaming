const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const express = require('express');
const { initialize } = require('express-openapi');

test('REST initializes from the bundled YAML API definition', async () => {
    const app = express();
    const framework = await initialize({
        app,
        apiDoc: path.resolve(__dirname, '../apidoc/api-definition-base.yml'),
        paths: []
    });
    assert.equal(framework.apiDoc.openapi, '3.1.0');
    assert.equal(framework.apiDoc.servers[0].url, '/api');
    assert.ok(framework.apiDoc.components.schemas.Streamer);
});
