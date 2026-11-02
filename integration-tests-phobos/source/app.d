/// Integration test runner for thread mode (blocking Phobos sockets).
module app;

import integrationtests.harness;

int main()
{
    return runAllTests(RunnerContext("phobos")) == 0 ? 0 : 1;
}
