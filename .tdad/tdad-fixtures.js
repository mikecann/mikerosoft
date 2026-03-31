/**
 * AUTO-GENERATED FILE - DO NOT EDIT
 * This file is automatically regenerated before each test run.
 * Any manual changes will be overwritten.
 *
 * Source: FixturesGenerator.scaffoldFixturesFile()
 */

/**
 * TDAD Test Fixtures - Centralized trace capture for Golden Packet
 *
 * This file extends Playwright's test with automatic:
 * - API request/response capture
 * - Console log capture
 * - Page error capture
 * - Accessibility tree snapshot (via ariaSnapshot for AI debugging)
 * - JS coverage collection
 *
 * IMPORTANT: Uses PER-WORKER files to avoid race conditions.
 * Each worker writes to coverage-worker-{index}.json
 * CoverageParser merges them after test run completes.
 *
 * Usage in test files:
 *   const { test, expect } = require('./tdad-fixtures');
 */
const { test: base, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

// Workspace root - derive from fixtures file location (.tdad/tdad-fixtures.js)
const workspaceRoot = path.dirname(__dirname);

// Coverage file management - PER-WORKER files to avoid race conditions
const coverageDir = path.join(workspaceRoot, '.tdad', 'coverage');
const workerIndex = process.env.TEST_WORKER_INDEX || process.pid.toString();
const coveragePath = path.join(coverageDir, `coverage-worker-${workerIndex}.json`);

/**
 * Write trace data incrementally - each worker writes to its own file
 */
function writeTraceIncremental(testTitle, traceUpdate) {
    try {
        if (!fs.existsSync(coverageDir)) {
            fs.mkdirSync(coverageDir, { recursive: true });
        }

        let existingData = { jsCoverage: [], testTraces: {}, workerIndex: workerIndex };
        if (fs.existsSync(coveragePath)) {
            try {
                existingData = JSON.parse(fs.readFileSync(coveragePath, 'utf-8'));
            } catch (e) { /* Start fresh on parse error */ }
        }

        if (!existingData.testTraces[testTitle]) {
            existingData.testTraces[testTitle] = {
                status: 'running',
                apiRequests: [],
                consoleLogs: [],
                pageErrors: [],
                actionResult: null,
                domSnapshot: null,
                screenshotPath: null
            };
        }

        const trace = existingData.testTraces[testTitle];

        if (traceUpdate.apiRequest) {
            trace.apiRequests.push(traceUpdate.apiRequest);
        }
        if (traceUpdate.consoleLog) {
            trace.consoleLogs.push(traceUpdate.consoleLog);
        }
        if (traceUpdate.pageError) {
            trace.pageErrors.push(traceUpdate.pageError);
        }
        if (traceUpdate.status) {
            trace.status = traceUpdate.status;
        }
        if (traceUpdate.domSnapshot) {
            trace.domSnapshot = traceUpdate.domSnapshot;
        }
        if (traceUpdate.screenshotPath) {
            trace.screenshotPath = traceUpdate.screenshotPath;
        }
        if (traceUpdate.actionResult !== undefined) {
            trace.actionResult = traceUpdate.actionResult;
        }
        if (traceUpdate.jsCoverage) {
            existingData.jsCoverage.push(...traceUpdate.jsCoverage);
        }

        fs.writeFileSync(coveragePath, JSON.stringify(existingData, null, 2));
    } catch (error) {
        Logger.error('[TDAD] Failed to write trace:', error);
    }
}

// Extended test with TDAD trace capture
const test = base.extend({
    tdadTrace: [async ({ page }, use, testInfo) => {
        const testTitle = testInfo.title;

        writeTraceIncremental(testTitle, { status: 'running' });

        let coverageStarted = false;
        try {
            await page.coverage.startJSCoverage();
            coverageStarted = true;
        } catch (e) { /* Coverage not available in non-Chromium */ }

        const pendingRequests = new Map();

        page.on('request', (request) => {
            const url = request.url();
            if (!url.includes('/api/')) return;

            const entry = {
                method: request.method(),
                url: url,
                requestBody: null,
                responseBody: null,
                status: null,
                timestamp: Date.now()
            };

            const contentType = request.headers()['content-type'] || '';
            if (contentType.includes('multipart/form-data')) {
                entry.requestBody = '[FormData - file upload]';
            } else {
                try {
                    const postData = request.postData();
                    entry.requestBody = postData ? JSON.parse(postData) : null;
                } catch (e) {
                    entry.requestBody = request.postData();
                }
            }

            pendingRequests.set(url + request.method(), entry);
        });

        page.on('response', async (response) => {
            const request = response.request();
            const url = request.url();
            if (!url.includes('/api/')) return;

            const key = url + request.method();
            let entry = pendingRequests.get(key);

            if (!entry) {
                entry = {
                    method: request.method(),
                    url: url,
                    requestBody: null,
                    responseBody: null,
                    status: null,
                    timestamp: Date.now()
                };
                const contentType = request.headers()['content-type'] || '';
                if (contentType.includes('multipart/form-data')) {
                    entry.requestBody = '[FormData - file upload]';
                } else {
                    try {
                        const postData = request.postData();
                        entry.requestBody = postData ? JSON.parse(postData) : null;
                    } catch (e) {
                        entry.requestBody = request.postData();
                    }
                }
            }

            entry.status = response.status();

            try {
                const body = await response.text();
                entry.responseBody = body ? JSON.parse(body) : null;
            } catch (e) {
                entry.responseBody = null;
            }

            writeTraceIncremental(testTitle, { apiRequest: entry });
            pendingRequests.delete(key);
        });

        page.on('requestfailed', (request) => {
            const url = request.url();
            if (!url.includes('/api/')) return;

            const key = url + request.method();
            let entry = pendingRequests.get(key);

            if (!entry) {
                entry = {
                    method: request.method(),
                    url: url,
                    requestBody: null,
                    responseBody: null,
                    status: null,
                    timestamp: Date.now()
                };
                const contentType = request.headers()['content-type'] || '';
                if (contentType.includes('multipart/form-data')) {
                    entry.requestBody = '[FormData - file upload]';
                } else {
                    try {
                        const postData = request.postData();
                        entry.requestBody = postData ? JSON.parse(postData) : null;
                    } catch (e) {
                        entry.requestBody = request.postData();
                    }
                }
            }

            entry.status = 0;
            entry.responseBody = { error: request.failure()?.errorText || 'Network error' };
            writeTraceIncremental(testTitle, { apiRequest: entry });
            pendingRequests.delete(key);
        });

        page.on('console', (msg) => {
            const logEntry = {
                type: msg.type(),
                text: msg.text(),
                location: msg.location() ? `${msg.location().url}:${msg.location().lineNumber}` : null,
                timestamp: Date.now()
            };
            writeTraceIncremental(testTitle, { consoleLog: logEntry });
        });

        async function captureSnapshot() {
            try {
                const ariaYaml = await page.locator('body').ariaSnapshot();
                if (ariaYaml) {
                    return {
                        type: 'accessibility',
                        url: page.url(),
                        tree: ariaYaml
                    };
                }
            } catch (e) { /* Page might be closed */ }
            return null;
        }

        async function captureScreenshot(testTitle, testFile) {
            try {
                let workflowPath = '';
                const workflowsMatch = testFile.match(/\.tdad[\\/]workflows[\\/](.+)[\\/][^\\/]+\.test\.js$/);
                if (workflowsMatch) {
                    workflowPath = workflowsMatch[1].replace(/\\/g, '/');
                }

                const safeTestTitle = testTitle
                    .toLowerCase()
                    .replace(/[\s/\\]+/g, '-')
                    .replace(/[^a-z0-9-]/g, '')
                    .replace(/-+/g, '-')
                    .replace(/^-|-$/g, '')
                    .substring(0, 50);

                const screenshotDir = workflowPath
                    ? path.join(workspaceRoot, '.tdad', 'debug', workflowPath, 'screenshots')
                    : path.join(workspaceRoot, '.tdad', 'debug', 'screenshots');
                if (!fs.existsSync(screenshotDir)) {
                    fs.mkdirSync(screenshotDir, { recursive: true });
                }

                const fileName = `${safeTestTitle}.png`;
                const filePath = path.join(screenshotDir, fileName);
                const relativePath = workflowPath
                    ? `.tdad/debug/${workflowPath}/screenshots/${fileName}`
                    : `.tdad/debug/screenshots/${fileName}`;

                await page.screenshot({ path: filePath, fullPage: true });

                return relativePath;
            } catch (e) {
                return null;
            }
        }

        /**
         * Save trace JSON file directly during test teardown
         * Ensures trace files are generated regardless of how tests are run (CLI or UI)
         */
        function saveTraceFile(testTitle, testFile, trace, testStatus, testDuration, testError) {
            try {
                let workflowPath = '';
                const workflowsMatch = testFile.match(/\.tdad[\\/]workflows[\\/](.+)[\\/][^\\/]+\.test\.js$/);
                if (workflowsMatch) {
                    workflowPath = workflowsMatch[1].replace(/\\/g, '/');
                }
                if (!workflowPath) return;

                const safeTestTitle = testTitle
                    .toLowerCase()
                    .replace(/[\s/\\]+/g, '-')
                    .replace(/[^a-z0-9-]/g, '')
                    .replace(/-+/g, '-')
                    .replace(/^-|-$/g, '')
                    .substring(0, 50);

                const traceDir = path.join(workspaceRoot, '.tdad', 'debug', workflowPath, 'trace-files');
                if (!fs.existsSync(traceDir)) {
                    fs.mkdirSync(traceDir, { recursive: true });
                }

                const fileName = `trace-${safeTestTitle}.json`;
                const filePath = path.join(traceDir, fileName);

                const traceData = {
                    testTitle: testTitle,
                    timestamp: new Date().toISOString(),
                    status: testStatus || trace.status || 'unknown',
                    duration: testDuration ?? trace.duration ?? null,
                    errorMessage: testError ? (testError.message || String(testError)) : null,
                    callStack: [],
                    apiRequests: trace.apiRequests || [],
                    consoleLogs: trace.consoleLogs || [],
                    pageErrors: trace.pageErrors || [],
                    actionResult: trace.actionResult || null,
                    domSnapshot: trace.domSnapshot || null,
                    screenshotPath: trace.screenshotPath || null
                };

                if (testError && testError.stack) {
                    const lines = testError.stack.split('\n');
                    for (const line of lines) {
                        const match = line.match(/at\s+(?:(.+?)\s+\()?(.+?):(\d+):(\d+)\)?/);
                        if (match) {
                            traceData.callStack.push({
                                func: match[1] || undefined,
                                file: match[2],
                                line: parseInt(match[3], 10),
                                column: parseInt(match[4], 10)
                            });
                        }
                    }
                }

                fs.writeFileSync(filePath, JSON.stringify(traceData, null, 2), 'utf-8');
            } catch (e) { /* Silently fail - trace file is non-critical */ }
        }

        page.on('pageerror', async (error) => {
            const errorEntry = {
                message: error.message,
                stack: error.stack,
                timestamp: Date.now()
            };
            writeTraceIncremental(testTitle, { pageError: errorEntry });
        });

        // Create request wrapper that logs API calls automatically
        const createRequestWrapper = () => {
            const methods = ['get', 'post', 'put', 'delete', 'patch', 'head', 'fetch'];
            const wrapper = {};

            methods.forEach(method => {
                wrapper[method] = async (url, options) => {
                    const startTime = Date.now();
                    const fullUrl = url.startsWith('http') ? url : url;

                    let requestBody = null;
                    if (options) {
                        if (options.multipart) {
                            requestBody = '[FormData - file upload]';
                        } else if (options.data) {
                            requestBody = options.data;
                        } else if (options.form) {
                            requestBody = options.form;
                        }
                    }

                    try {
                        const response = await page.request[method](url, options);
                        const duration = Date.now() - startTime;

                        let responseBody = null;
                        try {
                            const text = await response.text();
                            responseBody = text ? JSON.parse(text) : null;
                        } catch (e) {
                            // Response is not JSON, keep as null
                        }

                        const apiRequest = {
                            method: method.toUpperCase(),
                            url: response.url(),
                            status: response.status(),
                            requestBody,
                            responseBody,
                            duration,
                            timestamp: startTime
                        };

                        writeTraceIncremental(testTitle, { apiRequest });

                        return response;
                    } catch (error) {
                        const duration = Date.now() - startTime;
                        const apiRequest = {
                            method: method.toUpperCase(),
                            url: fullUrl,
                            status: 0,
                            requestBody,
                            responseBody: { error: error.message },
                            duration,
                            timestamp: startTime,
                            error: error.message
                        };

                        writeTraceIncremental(testTitle, { apiRequest });
                        throw error;
                    }
                };
            });

            return wrapper;
        };

        const traceRef = {
            addApiRequest: (req) => writeTraceIncremental(testTitle, { apiRequest: req }),
            addConsoleLog: (log) => writeTraceIncremental(testTitle, { consoleLog: log }),
            addPageError: (err) => writeTraceIncremental(testTitle, { pageError: err }),
            setActionResult: (result) => writeTraceIncremental(testTitle, { actionResult: result }),
            request: createRequestWrapper()
        };

        await use(traceRef);

        let jsCoverage = [];
        if (coverageStarted) {
            try {
                jsCoverage = await page.coverage.stopJSCoverage();
            } catch (e) { /* Ignore */ }
        }

        const isApiTest = /\[API(-\d+)?\]/.test(testTitle);
        const screenshotPath = isApiTest ? null : await captureScreenshot(testTitle, testInfo.file);

        const domSnapshot = isApiTest ? null : await captureSnapshot();

        const strippedCoverage = jsCoverage.map(entry => ({
            url: entry.url,
            functions: entry.functions
        }));
        writeTraceIncremental(testTitle, {
            status: testInfo.status,
            duration: testInfo.duration,
            jsCoverage: strippedCoverage,
            domSnapshot: domSnapshot,
            screenshotPath: screenshotPath
        });

        // Save trace JSON file directly (works for both CLI and UI test runs)
        const finalTrace = {
            status: testInfo.status,
            duration: testInfo.duration,
            apiRequests: [],
            consoleLogs: [],
            pageErrors: [],
            actionResult: null,
            domSnapshot: domSnapshot,
            screenshotPath: screenshotPath
        };
        // Read back the accumulated trace data from coverage file
        try {
            if (fs.existsSync(coveragePath)) {
                const coverageData = JSON.parse(fs.readFileSync(coveragePath, 'utf-8'));
                const testTrace = coverageData.testTraces?.[testTitle];
                if (testTrace) {
                    finalTrace.apiRequests = testTrace.apiRequests || [];
                    finalTrace.consoleLogs = testTrace.consoleLogs || [];
                    finalTrace.pageErrors = testTrace.pageErrors || [];
                    finalTrace.actionResult = testTrace.actionResult;
                }
            }
        } catch (e) { /* Use empty trace if read fails */ }
        saveTraceFile(testTitle, testInfo.file, finalTrace, testInfo.status, testInfo.duration, testInfo.error);
    }, { auto: true }]
});

module.exports = { test, expect };
