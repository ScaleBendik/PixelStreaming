const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

// Execute the production batch parser without setup, downloads, or server startup.
// The probe uses the same required-value CLI semantics as Wilbur.
test('Windows launcher preserves empty server values and all following arguments', {
    skip: process.platform !== 'win32'
}, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sw-launch-args-'));
    try {
        const common = fs.readFileSync(path.join(__dirname, '../platform_scripts/cmd/common.bat'), 'utf8');
        const probe = path.join(dir, 'probe.cjs');
        fs.writeFileSync(probe, `const { Command } = require(${JSON.stringify(require.resolve('commander'))});
const command = new Command().exitOverride()
    .option('--instance_agent_route_key <value>')
    .option('--instance_agent_scope_value <value>')
    .option('--instance_agent_version <value>')
    .option('--instance_agent_heartbeat_ms <value>')
    .option('--serve');
command.parse(process.argv);
console.log(JSON.stringify(command.opts()));`);
        const harness = path.join(dir, 'launch.bat');
        fs.writeFileSync(harness, [
            '@echo off', 'setlocal enabledelayedexpansion',
            'call :ParseArgs %*', 'if errorlevel 1 exit /b 1',
            `"${process.execPath}" "${probe}" %SERVER_ARGS% --serve`,
            'exit /b %errorlevel%', common
        ].join('\r\n'));
        const cases = [
            { args: '-- --instance_agent_route_key="" --instance_agent_scope_value="" --instance_agent_version="runtime 002" --instance_agent_heartbeat_ms=2000', route: '', scope: '', version: 'runtime 002', heartbeat: '2000' },
            { args: '-- --instance_agent_route_key="i-test" --instance_agent_scope_value="scope with spaces" --instance_agent_version="" --instance_agent_heartbeat_ms=2000', route: 'i-test', scope: 'scope with spaces', version: '', heartbeat: '2000' },
            { args: '-- --instance_agent_route_key ""', route: '' },
            { args: '-- --instance_agent_route_key="i-test" --instance_agent_scope_value="scope & pipes | brackets []"', route: 'i-test', scope: 'scope & pipes | brackets []' },
            { args: '--', route: undefined },
            { args: '', route: undefined }
        ];
        for (const fixture of cases) {
            const entry = path.join(dir, 'entry.bat');
            fs.writeFileSync(entry, `@echo off
call "${harness}" ${fixture.args}
`);
            const output = execFileSync(process.env.ComSpec || 'cmd.exe', ['/d', '/c', entry], {
                encoding: 'utf8', windowsHide: true, timeout: 10000
            });
            const actual = JSON.parse(output.trim());
            assert.equal(actual.instance_agent_route_key, fixture.route, fixture.args);
            assert.equal(actual.instance_agent_scope_value, fixture.scope, fixture.args);
            assert.equal(actual.instance_agent_version, fixture.version, fixture.args);
            assert.equal(actual.instance_agent_heartbeat_ms, fixture.heartbeat, fixture.args);
            assert.equal(actual.serve, true, fixture.args);
        }
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});
