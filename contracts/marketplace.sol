// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.20;

contract TaskMarketplace {
    enum TaskStatus { Open, Submitted, Verified, Accepted }

    struct Task {
        address creator;
        address solver;
        address verifier;
        uint256 bounty;
        string descriptionHash;
        string solutionHash;
        bool approved;
        uint256 deadline;
        TaskStatus status;
        // add: verifier percentage?, time for objection?, stake amount
    }

    uint256 taskCount;
    mapping(uint256 => Task) tasks;

    uint256 submitCost = 0.01 ether;
    uint256 verifyCost = 0.01 ether;
    

    event TaskPosted(uint256 taskId, address creator, uint256 bounty, string descriptionHash);
    event SolutionSubmitted(uint256 taskId, address solver, string solutionHash);
    event SolutionVerified(uint256 taskId, address verifier, bool approved);
    event TaskObjected(uint256 taskId, address objector);
    event TaskFinalized(uint256 taskId, bool success);

    constructor() {
    }

    //posting a task
    function postTask(string calldata _descriptionHash) external payable {
        require(msg.value > 0, "Must send bounty");

        taskCount++;
        Task storage t = tasks[taskCount];
        t.creator = msg.sender;
        t.bounty = msg.value;
        t.descriptionHash = _descriptionHash;
        t.approved = false;
        t.status = TaskStatus.Open;

        emit TaskPosted(taskCount, msg.sender, msg.value, _descriptionHash);
    }

    //submitting a solution
    function submitSolution(uint256 _taskId, string calldata _solutionHash) external payable {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");
        
        Task storage t = tasks[_taskId];
        require(t.status == TaskStatus.Open, "Task not open (yet)");
        require(msg.value == submitCost, "Stake required");
        require(t.solver == address(0), "A solution has already been submitted");

        t.solutionHash = _solutionHash;
        t.solver = msg.sender;
        t.status = TaskStatus.Submitted;

        emit SolutionSubmitted(_taskId, msg.sender, _solutionHash);
    }

    //verifying a solution
    function verifySolution(uint256 _taskId, bool _approved) external payable {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        Task storage t = tasks[_taskId];
        require(t.status == TaskStatus.Submitted, "Task not submitted (yet)");
        require(msg.value == verifyCost, "Stake required");
        require(t.verifier == address(0), "Already verified"); // redundant

        t.verifier = msg.sender;
        t.approved = _approved;
        t.deadline = block.timestamp + 1 minutes;
        t.status = TaskStatus.Verified;
        emit SolutionVerified(_taskId, msg.sender, _approved);
    }

    //objecting a solution
    function objectToVerification(uint256 _taskId) external {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        Task storage t = tasks[_taskId];
        require(t.status == TaskStatus.Verified, "Task not in review (yet)");
        require(block.timestamp < t.deadline, "Deadline passed");
        require(t.verifier != address(0), "No verifier yet"); // redundant

        payable(t.verifier).transfer(verifyCost); // refund stake (redo when we have idea how this should work)
        payable(t.solver).transfer(submitCost); // refund stake (redo when we have idea how this should work)
        //pay the remaining 1 ether to us haha :)
        
        t.status = TaskStatus.Open;
        t.solver = address(0);
        t.verifier = address(0);
        t.solutionHash = "";
        t.deadline = 0;
        t.approved = false;

        emit TaskObjected(_taskId, msg.sender);
    }

    //finalizing payments (no objection)
    function finalizeTask(uint256 _taskId) external {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        Task storage t = tasks[_taskId];
        require(t.status == TaskStatus.Verified, "Task not verified (yet)");
        require(block.timestamp > t.deadline, "Waiting time not passed yet");
        require(t.verifier != address(0), "No verifier yet"); // redundant

        if (t.approved) {
            t.status = TaskStatus.Accepted;
            uint256 solverReward = (t.bounty * 90) / 100;
            uint256 verifierBonus = (t.bounty * 10) / 100;
            payable(t.solver).transfer(solverReward + submitCost);
            payable(t.verifier).transfer(verifierBonus + verifyCost);
        } else { // redo this when we have an idea how this should work
            payable(t.verifier).transfer(submitCost + verifyCost);
            
            t.status = TaskStatus.Open;
            t.solver = address(0);
            t.verifier = address(0);
            t.solutionHash = "";
            t.deadline = 0;
            t.approved = false;
        }
        emit TaskFinalized(_taskId, t.approved);
    }

    function getTask(uint256 _taskId) external view returns (
        address creator,
        address solver,
        address verifier,
        uint256 bounty,
        string memory descriptionHash,
        string memory solutionHash,
        bool approved,
        uint256 deadline,
        TaskStatus status
    ) {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        Task storage t = tasks[_taskId];
        return (t.creator, t.solver, t.verifier, t.bounty, t.descriptionHash, t.solutionHash, t.approved, t.deadline, t.status);
    }

    function getRemainingTime(uint256 _taskId) external view returns (uint256 Seconds) {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        if (tasks[_taskId].deadline == 0 || tasks[_taskId].deadline < block.timestamp) {
            return 0;
        } else {
            return (tasks[_taskId].deadline - block.timestamp);
        }
    }

    function getTaskCount() external view returns (uint256) {
        return taskCount;
    }
}
