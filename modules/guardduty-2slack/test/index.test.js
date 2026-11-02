'use strict';

const { test } = require('node:test');
const assert = require('node:assert');

const { buildMessage, severityLabel } = require('../lambda/index');
const ec2Finding = require('../events/ec2-ssh-bruteforce.json');
const s3Finding = require('../events/s3-anomalous-exfiltration.json');
const iamFinding = require('../events/iam-anomalous-behavior.json');

test('severityLabel maps GuardDuty severities', () => {
  assert.strictEqual(severityLabel(8), 'HIGH');
  assert.strictEqual(severityLabel(5), 'MEDIUM');
  assert.strictEqual(severityLabel(2), 'LOW');
});

test('buildMessage includes the finding title and instance (EC2)', () => {
  const message = buildMessage(ec2Finding.detail);

  assert.match(message.text, /SSH brute force/);
  assert.match(message.blocks[1].elements[0].text, /i-0a1b2c3d4e5f60789/);
});

test('buildMessage survives an S3 finding (no instanceDetails)', () => {
  const message = buildMessage(s3Finding.detail);

  assert.match(message.text, /Anomalous S3 data access/);
  const context = message.blocks[1].elements[0].text;
  assert.match(context, /acme-claims-reports-prod/);
  assert.match(context, /claims-reports-uploader/);
});

test('buildMessage survives an IAM finding (accessKeyDetails)', () => {
  const message = buildMessage(iamFinding.detail);

  assert.match(message.text, /Unusual discovery API calls/);
  assert.match(message.blocks[1].elements[0].text, /claims-reports-uploader/);
});
