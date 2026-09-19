"""Tests for the three automation scripts, against moto-mocked AWS APIs."""
import os
import sys

import boto3
import pytest
from moto import mock_aws

os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
os.environ["AWS_ACCESS_KEY_ID"] = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
os.environ["AWS_REGION"] = "us-east-1"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "automation"))
import nonprod_scheduler  # noqa: E402
import patch_compliance_report  # noqa: E402
import resource_health_check  # noqa: E402


# ------------------------------------------------------------------ nonprod_scheduler
@pytest.fixture
def asg():
    with mock_aws():
        ec2 = boto3.client("ec2")
        vpc = ec2.create_vpc(CidrBlock="10.0.0.0/16")["Vpc"]["VpcId"]
        subnet = ec2.create_subnet(VpcId=vpc, CidrBlock="10.0.1.0/24")["Subnet"]["SubnetId"]
        auto = boto3.client("autoscaling")
        auto.create_launch_configuration(LaunchConfigurationName="lc", ImageId="ami-12345678", InstanceType="t3.micro")
        auto.create_auto_scaling_group(AutoScalingGroupName="cops-app-asg", LaunchConfigurationName="lc",
                                       MinSize=2, MaxSize=4, DesiredCapacity=2, VPCZoneIdentifier=subnet)
        yield auto


def _asg(auto):
    return auto.describe_auto_scaling_groups(AutoScalingGroupNames=["cops-app-asg"])["AutoScalingGroups"][0]


def test_stop_sets_min_and_desired_to_zero(asg):
    r = nonprod_scheduler.handler({"action": "stop"}, None)
    g = _asg(asg)
    assert (g["MinSize"], g["DesiredCapacity"]) == (0, 0)
    assert r == {"asg": "cops-app-asg", "action": "stop", "min_size": 0, "desired_capacity": 0}


def test_start_restores_capacity(asg):
    nonprod_scheduler.handler({"action": "stop"}, None)
    nonprod_scheduler.handler({"action": "START"}, None)  # case-insensitive
    g = _asg(asg)
    assert (g["MinSize"], g["DesiredCapacity"]) == (2, 2)


def test_unknown_action_fails_loudly(asg):
    with pytest.raises(ValueError):
        nonprod_scheduler.handler({"action": "pause"}, None)
    with pytest.raises(ValueError):
        nonprod_scheduler.handler({}, None)
    assert _asg(asg)["DesiredCapacity"] == 2  # nothing changed


def test_aws_failure_is_raised_not_swallowed():
    with mock_aws():  # no ASG exists
        with pytest.raises(Exception):
            nonprod_scheduler.handler({"action": "stop"}, None)


# ------------------------------------------------------------------ patch_compliance_report
def test_compliance_pct_arithmetic():
    assert patch_compliance_report.compliance_pct({})[0] == 100.0
    pct, ok, bad = patch_compliance_report.compliance_pct(
        {"InstalledCount": 8, "InstalledOtherCount": 1, "MissingCount": 1, "FailedCount": 0, "InstalledPendingRebootCount": 0})
    assert (round(pct, 1), ok, bad) == (90.0, 9, 1)
    pct, _, _ = patch_compliance_report.compliance_pct({"InstalledCount": 0, "MissingCount": 3})
    assert pct == 0.0


class FakeSSM:
    """moto has no describe_instance_patch_states_for_patch_group; a paginator stub is enough."""
    def __init__(self, pages):
        self._pages = pages

    def get_paginator(self, name):
        assert name == "describe_instance_patch_states_for_patch_group"
        pages = self._pages

        class P:
            def paginate(self, **kw):
                return iter(pages)
        return P()


def test_report_paginates_and_exits_nonzero_below_threshold(monkeypatch, capsys):
    ssm = FakeSSM([
        {"InstancePatchStates": [{"InstanceId": "i-aaa", "InstalledCount": 10, "MissingCount": 0}]},
        {"InstancePatchStates": [{"InstanceId": "i-bbb", "InstalledCount": 7, "MissingCount": 3}]},
    ])
    monkeypatch.setattr(patch_compliance_report.boto3, "client", lambda *a, **k: ssm)
    monkeypatch.setattr(sys, "argv", ["patch_compliance_report.py", "--min-compliant", "95"])
    assert patch_compliance_report.main() == 1
    out = capsys.readouterr()
    assert "i-aaa" in out.out and "i-bbb" in out.out and "Instances: 2" in out.out
    assert "NON-COMPLIANT" in out.err and "i-bbb: 70.0%" in out.err


def test_report_compliant_exit_zero(monkeypatch, capsys):
    ssm = FakeSSM([{"InstancePatchStates": [{"InstanceId": "i-aaa", "InstalledCount": 10}]}])
    monkeypatch.setattr(patch_compliance_report.boto3, "client", lambda *a, **k: ssm)
    monkeypatch.setattr(sys, "argv", ["patch_compliance_report.py"])
    assert patch_compliance_report.main() == 0
    assert "COMPLIANT" in capsys.readouterr().out


def test_report_empty_inventory_is_visible_but_not_a_failure(monkeypatch, capsys):
    ssm = FakeSSM([{"InstancePatchStates": []}])
    monkeypatch.setattr(patch_compliance_report.boto3, "client", lambda *a, **k: ssm)
    monkeypatch.setattr(sys, "argv", ["patch_compliance_report.py"])
    assert patch_compliance_report.main() == 0
    assert "No managed instances" in capsys.readouterr().out


# ------------------------------------------------------------------ resource_health_check
@pytest.fixture
def lab():
    with mock_aws():
        ec2 = boto3.client("ec2")
        vpc = ec2.create_vpc(CidrBlock="10.0.0.0/16")["Vpc"]["VpcId"]
        s1 = ec2.create_subnet(VpcId=vpc, CidrBlock="10.0.1.0/24", AvailabilityZone="us-east-1a")["Subnet"]["SubnetId"]
        s2 = ec2.create_subnet(VpcId=vpc, CidrBlock="10.0.2.0/24", AvailabilityZone="us-east-1b")["Subnet"]["SubnetId"]
        elbv2 = boto3.client("elbv2")
        tg = elbv2.create_target_group(Name="cops-app-tg", Protocol="HTTP", Port=80, VpcId=vpc)["TargetGroups"][0]["TargetGroupArn"]
        inst = ec2.run_instances(ImageId="ami-12345678", MinCount=1, MaxCount=1, SubnetId=s1)["Instances"][0]["InstanceId"]
        elbv2.register_targets(TargetGroupArn=tg, Targets=[{"Id": inst, "Port": 80}])
        rds = boto3.client("rds")
        rds.create_db_instance(DBInstanceIdentifier="cops-db", DBInstanceClass="db.t3.micro", Engine="postgres",
                               MasterUsername="u", MasterUserPassword="passw0rd!!", AllocatedStorage=20)
        cw = boto3.client("cloudwatch")
        cw.put_metric_alarm(AlarmName="cops-alb-5xx", Namespace="AWS/ApplicationELB", MetricName="HTTPCode_ELB_5XX_Count",
                            Statistic="Sum", Period=60, EvaluationPeriods=1, Threshold=3, ComparisonOperator="GreaterThanThreshold")
        yield {"elbv2": elbv2, "rds": rds, "cw": cw, "tg": tg}


def test_health_check_healthy_lab_exits_zero(lab, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["resource_health_check.py"])
    assert resource_health_check.main() == 0
    out = capsys.readouterr().out
    assert "cops-app-tg: 1 target(s)" in out and "RDS cops-db: [OK ]" in out and "OVERALL: HEALTHY" in out


def test_health_check_alarm_in_alarm_state_exits_one(lab, monkeypatch, capsys):
    lab["cw"].set_alarm_state(AlarmName="cops-alb-5xx", StateValue="ALARM", StateReason="drill")
    monkeypatch.setattr(sys, "argv", ["resource_health_check.py"])
    assert resource_health_check.main() == 1
    err = capsys.readouterr()
    assert "[BAD] cops-alb-5xx: ALARM" in err.out and "OVERALL: UNHEALTHY" in err.err


def test_health_check_missing_resources_are_reported(monkeypatch, capsys):
    with mock_aws():
        monkeypatch.setattr(sys, "argv", ["resource_health_check.py"])
        assert resource_health_check.main() == 1
        out = capsys.readouterr().out
        assert "ERROR" in out or "NOT FOUND" in out


def test_check_alb_flags_unhealthy_target():
    class E:
        def describe_target_groups(self, Names):
            return {"TargetGroups": [{"TargetGroupArn": "arn:tg"}]}

        def describe_target_health(self, TargetGroupArn):
            return {"TargetHealthDescriptions": [
                {"Target": {"Id": "i-1"}, "TargetHealth": {"State": "healthy"}},
                {"Target": {"Id": "i-2"}, "TargetHealth": {"State": "unhealthy", "Reason": "Target.FailedHealthChecks"}},
            ]}
    ok, lines = resource_health_check.check_alb(E())
    assert not ok and any("[BAD] i-2: unhealthy (Target.FailedHealthChecks)" in l for l in lines)
