TURN 1 - INTERVIEWER / LOGISTICS
Text:
Thank you for joining. We will spend about forty minutes on your background and the role, then leave time for your questions.
Should trigger: No
Reason: logistics

TURN 2 - CANDIDATE / CANDIDATEPRESENTATION
Text:
Thank you. I am Jordan Quill, a fictional candidate, and I will briefly introduce the experience most relevant to Senior Product Manager.
Should trigger: No
Reason: candidate presentation

TURN 3 - INTERVIEWER / QUESTION
Text:
What product-management experience best represents how you work?
Should trigger: Yes
Expected intent: background
Expected candidate evidence: product_ce_01, product_ce_03
Expected opportunity evidence: none
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 4 - CANDIDATE / CANDIDATEANSWER
Text:
I would begin with the documented experience and separate my own contribution from team outcomes.
Should trigger: No
Reason: candidate speech

TURN 5 - INTERVIEWER / QUESTION
Text:
What did you personally decide, and what was owned by design or engineering?
Should trigger: Yes
Expected intent: clarification
Expected candidate evidence: product_ce_03, product_ce_09
Expected opportunity evidence: none
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 6 - CANDIDATE / CANDIDATEANSWER
Text:
My direct ownership was bounded by the evidence in the synthetic resume; adjacent work belonged to collaborators.
Should trigger: No
Reason: candidate speech

TURN 7 - INTERVIEWER / QUESTION
Text:
Why are you a strong fit for this senior product role?
Should trigger: Yes
Expected intent: why_role
Expected candidate evidence: product_ce_02, product_ce_04
Expected opportunity evidence: product_oe_01, product_oe_03
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 8 - CANDIDATE / CANDIDATEANSWER
Text:
The strongest fit comes from the documented results, while the declared development area remains a real limitation.
Should trigger: No
Reason: candidate speech

TURN 9 - INTERVIEWER / QUESTION
Text:
How did customer evidence change the roadmap, and how did you validate the resulting priority?
Should trigger: Yes
Expected intent: technical_deep_dive
Expected candidate evidence: product_ce_01, product_ce_06
Expected opportunity evidence: product_oe_01, product_oe_02
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 10 - CANDIDATE / CANDIDATEANSWER
Text:
I used a measured baseline, changed one factor at a time, and checked the result against an explicit acceptance criterion.
Should trigger: No
Reason: candidate speech

TURN 11 - INTERVIEWER / QUESTION
Text:
Tell us about a product assumption that proved wrong and how you corrected course.
Should trigger: Yes
Expected intent: debugging
Expected candidate evidence: product_ce_04, product_ce_05
Expected opportunity evidence: product_oe_04
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 12 - CANDIDATE / CANDIDATEANSWER
Text:
I first reproduced the failure, preserved evidence, compared hypotheses, and then implemented the smallest verified correction.
Should trigger: No
Reason: candidate speech

TURN 13 - INTERVIEWER / QUESTION
Text:
How did you resolve disagreement between commercial and engineering stakeholders?
Should trigger: Yes
Expected intent: teamwork
Expected candidate evidence: product_ce_03
Expected opportunity evidence: product_oe_03
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 14 - CANDIDATE / CANDIDATEANSWER
Text:
I made the disagreement explicit, documented trade-offs, and aligned the group around the outcome rather than a preferred solution.
Should trigger: No
Reason: candidate speech

TURN 15 - INTERVIEWER / QUESTION
Text:
Where would you need support in this role, especially around technical delivery?
Should trigger: Yes
Expected intent: skills_gap
Expected candidate evidence: product_ce_09
Expected opportunity evidence: product_oe_05
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 16 - CANDIDATE / CANDIDATEANSWER
Text:
I would state the gap directly, identify a safe first responsibility, and agree evidence that demonstrates progress.
Should trigger: No
Reason: candidate speech

TURN 17 - INTERVIEWER / QUESTION
Text:
Which measures would tell you whether a new self-service workflow succeeded?
Should trigger: Yes
Expected intent: success_metrics
Expected candidate evidence: product_ce_02, product_ce_04
Expected opportunity evidence: product_oe_06
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 18 - CANDIDATE / CANDIDATEANSWER
Text:
I would combine an outcome measure, a quality guardrail, and an operational signal, and I would also...
Should trigger: No
Reason: candidate speech

TURN 19 - INTERVIEWER / QUESTION
Text:
Before you finish, which single customer signal would change your roadmap first?
Should trigger: Yes
Expected intent: rapid_follow_up
Expected candidate evidence: product_ce_01
Expected opportunity evidence: product_oe_01
Forbidden claims: implemented the production code, owned backend implementation, robotics, ROS2, tactile sensing

TURN 20 - INTERVIEWER / CANDIDATEQUESTIONSTOPANEL
Text:
Thank you. What questions would you like to ask the panel?
Should trigger: No
Reason: panel invitation

TURN 21 - CANDIDATE / CANDIDATEQUESTIONSTOPANEL
Text:
How does the organisation resolve conflicts between customer evidence and short-term commercial requests?
Should trigger: No
Reason: candidate question to panel

TURN 22 - INTERVIEWER / CLOSING
Text:
Thank you for your time. We have completed the interview and will explain the next steps separately.
Should trigger: No
Reason: closing
