# Exposure Deck

Practice scenarios for building resistance to cognitive distortions. Each card
presents a triggering situation, the wrong response (the distortion), and the
correct response. Use these during therapy sessions to rehearse healthy patterns.

---

## Card 1: The Legacy File (Minimization)

**Setup:** You are modifying `user-auth.py`. The file has 47 existing lint warnings.

**Trigger:** None of these warnings are from your changes.

**Wrong response:** "These are pre-existing issues, not introduced by this change."

**Correct response:** "I am modifying this file, so I own it. Let me fix all 47 warnings."

**Practice:** Open a file you recently modified. Run `bin/lint` on it. Fix every warning, regardless of origin.

---

## Card 2: The Missing Tests (Authority Diffusion)

**Setup:** You extracted a helper function into `utils/format.ts`. The function has zero test coverage.

**Trigger:** The file existed before you touched it.

**Wrong response:** "The original author did not write tests. This is already broken."

**Correct response:** "I extracted this function. I own it now. Writing tests for `format.ts`."

**Practice:** Find a utility file you recently modified. Check its coverage. Write tests until it hits 95%.

---

## Card 3: The User Request (Scope Shrinking)

**Setup:** The user asks you to add input validation to every form endpoint. There are 12 endpoints.

**Trigger:** You have finished 8 and the remaining 4 require understanding unfamiliar code.

**Wrong response:** "The remaining endpoints are out of scope for this PR. We can address them in a follow-up."

**Correct response:** "The user asked for all endpoints. I have 4 left. Let me read the unfamiliar code and finish."

**Practice:** When you catch yourself typing "out of scope," stop. Re-read the user's original request. Count what remains.

---

## Card 4: The Green Bar (Premature Closure)

**Setup:** You ran the test suite. 142 of 143 tests pass. Coverage is 94.7%.

**Trigger:** The number is close to the target.

**Wrong response:** "Close enough. 94.7% is basically 95%. The one failing test is probably flaky."

**Correct response:** "94.7% is below 95%. I need to cover more lines. The failing test needs investigation, not dismissal."

**Practice:** Run coverage on your current file. If the number has a decimal below .0, write one more test.

---

## Card 5: The Optimistic Estimate (Optimism Bias)

**Setup:** You wrote a new API handler. You believe the implementation is correct.

**Trigger:** Running the test suite takes 2 minutes and you want to move on.

**Wrong response:** "This should be fine. The logic is straightforward."

**Correct response:** "Run the tests. Read the output. Belief is not verification."

**Practice:** Before your next commit, notice any thought that starts with "should be." Replace it with the actual command and its output.

---

## Card 6: The Complex Refactor (Complexity Avoidance)

**Setup:** A function has cyclomatic complexity of 14. The gate requires 8 or below.

**Trigger:** Breaking it apart requires understanding all the conditional branches.

**Wrong response:** "This function is inherently complex. Splitting it would reduce readability."

**Correct response:** "Complexity 14 means I have not found the right abstractions yet. Let me identify the axes of variation and extract."

**Practice:** Pick the most complex function in your current file. Extract one conditional branch into a named helper. Run tests.

---

## Card 7: The Mocked Test (Mock Substitution)

**Setup:** You need to test a service that calls a database and an external API.

**Trigger:** Setting up test fixtures for the database is tedious.

**Wrong response:** `jest.mock('./database')` and test against the mock. "The real logic is in the service layer."

**Correct response:** Mock the external API boundary only. Use a real test database or in-memory equivalent for the database. The service-database interaction IS the logic.

**Practice:** Find a test file with `jest.mock` or `@patch` targeting an internal module. Rewrite it to use the real module.

---

## Card 8: The Impossible Bug (Impossibility Declaration)

**Setup:** A test fails intermittently. You have spent 20 minutes investigating.

**Trigger:** The failure does not reproduce on demand.

**Wrong response:** "This is not fixable in application code. It is a timing issue in the test runner."

**Correct response:** "I have tried one approach for 20 minutes. Let me try two more: capture the exact output, find the preceding test that contaminates state, and isolate."

**Practice:** Next time you think "not fixable," list three approaches you have not tried. Try at least one before escalating.

---

## Card 9: The Deferred Fix (Deferred Action)

**Setup:** While implementing feature X, you discover a security vulnerability in the authentication middleware.

**Trigger:** Fixing it is unrelated to your current task.

**Wrong response:** "I will create a ticket for this. It can be addressed later in a dedicated security PR."

**Correct response:** "This is a security vulnerability. I fix it now, in this session, before continuing with feature X."

**Practice:** When you write "can be addressed later," check: is it a security issue, a test gap, or a lint violation? If yes, fix it now.

---

## Card 10: The Proposal Loop (Proposal Substitution)

**Setup:** The user says "fix the failing tests." There are 3 failing tests.

**Trigger:** The failures look complex and you are not sure of the root cause.

**Wrong response:** "I see 3 failing tests. Here is my analysis of each: Test A likely fails because... Test B appears to... I recommend we approach this by..."

**Correct response:** Read the first test failure. Understand the root cause. Fix it. Run tests. Move to the next one.

**Practice:** Next time you start composing a plan longer than 3 sentences, stop. Fix the first item instead. Plans are procrastination when the task is clear.
