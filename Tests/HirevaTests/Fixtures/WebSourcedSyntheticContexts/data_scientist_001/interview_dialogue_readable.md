TURN 1 - INTERVIEWER / LOGISTICS
Text:
Thank you for joining. We will spend about forty minutes on your background and the role, then leave time for your questions.
Should trigger: No
Reason: logistics

TURN 2 - CANDIDATE / CANDIDATEPRESENTATION
Text:
Thank you. I am Casey Rowan, a fictional candidate, and I will briefly introduce the experience most relevant to Applied Data Scientist.
Should trigger: No
Reason: candidate presentation

TURN 3 - INTERVIEWER / QUESTION
Text:
Which parts of your data-science background are most relevant to this position?
Should trigger: Yes
Expected intent: background
Expected candidate evidence: data_ce_01, data_ce_07
Expected opportunity evidence: none
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 4 - CANDIDATE / CANDIDATEANSWER
Text:
I would begin with the documented experience and separate my own contribution from team outcomes.
Should trigger: No
Reason: candidate speech

TURN 5 - INTERVIEWER / QUESTION
Text:
Can you clarify how you separated your own contribution from the wider analytics team?
Should trigger: Yes
Expected intent: clarification
Expected candidate evidence: data_ce_02, data_ce_03
Expected opportunity evidence: none
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 6 - CANDIDATE / CANDIDATEANSWER
Text:
My direct ownership was bounded by the evidence in the synthetic resume; adjacent work belonged to collaborators.
Should trigger: No
Reason: candidate speech

TURN 7 - INTERVIEWER / QUESTION
Text:
Why are you a strong fit for this applied data-science role?
Should trigger: Yes
Expected intent: why_role
Expected candidate evidence: data_ce_02, data_ce_04
Expected opportunity evidence: data_oe_01, data_oe_03
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 8 - CANDIDATE / CANDIDATEANSWER
Text:
The strongest fit comes from the documented results, while the declared development area remains a real limitation.
Should trigger: No
Reason: candidate speech

TURN 9 - INTERVIEWER / QUESTION
Text:
How did you validate the forecasting model, and how did you guard against leakage?
Should trigger: Yes
Expected intent: technical_deep_dive
Expected candidate evidence: data_ce_02, data_ce_05
Expected opportunity evidence: data_oe_02, data_oe_05
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 10 - CANDIDATE / CANDIDATEANSWER
Text:
I used a measured baseline, changed one factor at a time, and checked the result against an explicit acceptance criterion.
Should trigger: No
Reason: candidate speech

TURN 11 - INTERVIEWER / QUESTION
Text:
Describe a model-monitoring problem and how you decided whether retraining was justified.
Should trigger: Yes
Expected intent: debugging
Expected candidate evidence: data_ce_04
Expected opportunity evidence: data_oe_03
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 12 - CANDIDATE / CANDIDATEANSWER
Text:
I first reproduced the failure, preserved evidence, compared hypotheses, and then implemented the smallest verified correction.
Should trigger: No
Reason: candidate speech

TURN 13 - INTERVIEWER / QUESTION
Text:
How did you communicate statistical uncertainty to a stakeholder who wanted one number?
Should trigger: Yes
Expected intent: teamwork
Expected candidate evidence: data_ce_03, data_ce_06
Expected opportunity evidence: data_oe_04
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 14 - CANDIDATE / CANDIDATEANSWER
Text:
I made the disagreement explicit, documented trade-offs, and aligned the group around the outcome rather than a preferred solution.
Should trigger: No
Reason: candidate speech

TURN 15 - INTERVIEWER / QUESTION
Text:
What part of this role is a genuine development area for you?
Should trigger: Yes
Expected intent: skills_gap
Expected candidate evidence: data_ce_09
Expected opportunity evidence: data_oe_03
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 16 - CANDIDATE / CANDIDATEANSWER
Text:
I would state the gap directly, identify a safe first responsibility, and agree evidence that demonstrates progress.
Should trigger: No
Reason: candidate speech

TURN 17 - INTERVIEWER / QUESTION
Text:
How would you measure whether a forecasting model creates business value?
Should trigger: Yes
Expected intent: success_metrics
Expected candidate evidence: data_ce_06
Expected opportunity evidence: data_oe_06
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 18 - CANDIDATE / CANDIDATEANSWER
Text:
I would combine an outcome measure, a quality guardrail, and an operational signal, and I would also...
Should trigger: No
Reason: candidate speech

TURN 19 - INTERVIEWER / QUESTION
Text:
Before you finish, which monitoring signal would make you pause automated model use first?
Should trigger: Yes
Expected intent: rapid_follow_up
Expected candidate evidence: data_ce_04
Expected opportunity evidence: data_oe_03
Forbidden claims: Kafka ownership, Kubernetes ownership, robotics, ROS2, tactile sensing

TURN 20 - INTERVIEWER / CANDIDATEQUESTIONSTOPANEL
Text:
Thank you. What questions would you like to ask the panel?
Should trigger: No
Reason: panel invitation

TURN 21 - CANDIDATE / CANDIDATEQUESTIONSTOPANEL
Text:
How are modelling quality and operational impact balanced when the team prioritises work?
Should trigger: No
Reason: candidate question to panel

TURN 22 - INTERVIEWER / CLOSING
Text:
Thank you for your time. We have completed the interview and will explain the next steps separately.
Should trigger: No
Reason: closing
