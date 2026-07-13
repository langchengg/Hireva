TURN 1 - INTERVIEWER / LOGISTICS
Text:
Thank you for joining. We will spend about forty minutes on your background and the role, then leave time for your questions.
Should trigger: No
Reason: logistics

TURN 2 - CANDIDATE / CANDIDATEPRESENTATION
Text:
Thank you. I am Morgan Vale, a fictional candidate, and I will briefly introduce the experience most relevant to Senior Backend Software Engineer.
Should trigger: No
Reason: candidate presentation

TURN 3 - INTERVIEWER / QUESTION
Text:
Could you summarise the backend experience that best prepared you for this role?
Should trigger: Yes
Expected intent: background
Expected candidate evidence: backend_ce_01, backend_ce_07
Expected opportunity evidence: none
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 4 - CANDIDATE / CANDIDATEANSWER
Text:
I would begin with the documented experience and separate my own contribution from team outcomes.
Should trigger: No
Reason: candidate speech

TURN 5 - INTERVIEWER / QUESTION
Text:
To clarify, what part of that work did you personally own?
Should trigger: Yes
Expected intent: clarification
Expected candidate evidence: backend_ce_01, backend_ce_02
Expected opportunity evidence: none
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 6 - CANDIDATE / CANDIDATEANSWER
Text:
My direct ownership was bounded by the evidence in the synthetic resume; adjacent work belonged to collaborators.
Should trigger: No
Reason: candidate speech

TURN 7 - INTERVIEWER / QUESTION
Text:
Why are you a strong fit for this senior backend role?
Should trigger: Yes
Expected intent: why_role
Expected candidate evidence: backend_ce_02, backend_ce_03
Expected opportunity evidence: backend_oe_01, backend_oe_03
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 8 - CANDIDATE / CANDIDATEANSWER
Text:
The strongest fit comes from the documented results, while the declared development area remains a real limitation.
Should trigger: No
Reason: candidate speech

TURN 9 - INTERVIEWER / QUESTION
Text:
How did you diagnose the API latency, and how did you prove the database change was safe?
Should trigger: Yes
Expected intent: technical_deep_dive
Expected candidate evidence: backend_ce_02, backend_ce_05
Expected opportunity evidence: backend_oe_02, backend_oe_06
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 10 - CANDIDATE / CANDIDATEANSWER
Text:
I used a measured baseline, changed one factor at a time, and checked the result against an explicit acceptance criterion.
Should trigger: No
Reason: candidate speech

TURN 11 - INTERVIEWER / QUESTION
Text:
Tell us about the duplicate-message incident and the debugging decisions you made.
Should trigger: Yes
Expected intent: debugging
Expected candidate evidence: backend_ce_04
Expected opportunity evidence: backend_oe_03
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 12 - CANDIDATE / CANDIDATEANSWER
Text:
I first reproduced the failure, preserved evidence, compared hypotheses, and then implemented the smallest verified correction.
Should trigger: No
Reason: candidate speech

TURN 13 - INTERVIEWER / QUESTION
Text:
How did you align other teams during the API migration?
Should trigger: Yes
Expected intent: teamwork
Expected candidate evidence: backend_ce_06
Expected opportunity evidence: backend_oe_07
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 14 - CANDIDATE / CANDIDATEANSWER
Text:
I made the disagreement explicit, documented trade-offs, and aligned the group around the outcome rather than a preferred solution.
Should trigger: No
Reason: candidate speech

TURN 15 - INTERVIEWER / QUESTION
Text:
Which requirement would stretch you most, and how would you close that gap?
Should trigger: Yes
Expected intent: skills_gap
Expected candidate evidence: backend_ce_09
Expected opportunity evidence: backend_oe_04
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 16 - CANDIDATE / CANDIDATEANSWER
Text:
I would state the gap directly, identify a safe first responsibility, and agree evidence that demonstrates progress.
Should trigger: No
Reason: candidate speech

TURN 17 - INTERVIEWER / QUESTION
Text:
What metrics would you use to judge service reliability in your first three months?
Should trigger: Yes
Expected intent: success_metrics
Expected candidate evidence: backend_ce_03, backend_ce_04
Expected opportunity evidence: backend_oe_06
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 18 - CANDIDATE / CANDIDATEANSWER
Text:
I would combine an outcome measure, a quality guardrail, and an operational signal, and I would also...
Should trigger: No
Reason: candidate speech

TURN 19 - INTERVIEWER / QUESTION
Text:
Before you finish, which single reliability signal would you investigate first and why?
Should trigger: Yes
Expected intent: rapid_follow_up
Expected candidate evidence: backend_ce_03
Expected opportunity evidence: backend_oe_06
Forbidden claims: robotics, ROS2, tactile sensing, robot grasping, Manchester Robotics MSc

TURN 20 - INTERVIEWER / CANDIDATEQUESTIONSTOPANEL
Text:
Thank you. What questions would you like to ask the panel?
Should trigger: No
Reason: panel invitation

TURN 21 - CANDIDATE / CANDIDATEQUESTIONSTOPANEL
Text:
How does the team balance feature delivery with reliability work during planning?
Should trigger: No
Reason: candidate question to panel

TURN 22 - INTERVIEWER / CLOSING
Text:
Thank you for your time. We have completed the interview and will explain the next steps separately.
Should trigger: No
Reason: closing
