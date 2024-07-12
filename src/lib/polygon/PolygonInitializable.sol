// SPDX-License-Identifier: GPL
pragma solidity 0.8.19;

contract PolygonInitializable {
    bool inited = false;

    modifier polygonInitializer() {
        require(!inited, "already inited");
        _;
        inited = true;
    }
}
