#!/usr/bin/env node
// Setup's check for the browser Relay's Browser page drives: prints the
// executable it would use and exits 0, or exits 1 when there is none. It asks
// the backend's own findBrowser, so setup and the running backend agree.
'use strict';

const path = require('path');

require('dotenv').config({ path: path.join(__dirname, '..', '.env'), quiet: true });

const { findBrowser } = require('../lib/browser-manager');

const found = findBrowser();
if (found) console.log(found);
process.exitCode = found ? 0 : 1;
