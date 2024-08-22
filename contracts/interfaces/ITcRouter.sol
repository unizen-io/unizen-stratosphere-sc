interface ITcRouter {
     function depositWithExpiry(address payable vault, address asset, uint amount, string memory memo, uint expiration) external payable;
}