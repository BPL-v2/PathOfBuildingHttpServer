-- Dat View
--
-- Class: Dat List
-- Dat list control.
--
local DatListClass = newClass("DatListControl", "ListControl", function(self, anchor, rect)
	self.originalList = main.datFileList
	self.searchBuf = ""
	self.filteredList = self.originalList
	self.ListControl(anchor, rect, 14, "VERTICAL", false, self.filteredList)
end)

function DatListClass:BuildFilteredList()
	local search = self.searchBuf:lower()
	if search == "" then
		self.filteredList = self.originalList
	else
		self.filteredList = {}
		for _, file in ipairs(self.originalList) do
			if file.name:lower():find(search, 1, true) then
				table.insert(self.filteredList, file)
			end
		end
	end
	self.list = self.filteredList
end

function DatListClass:GetRowValue(column, index, datFile)
	if column == 1 then
		return "^7"..datFile.name
	end
end

function DatListClass:OnSelect(index, datFile)
	main:SetCurrentDat(datFile)
end

function DatListClass:OnAnyKeyDown(key)
	if key:match("%a") then
		for i = 1, #self.list do
			local valIndex = ((self.selIndex or 1) - 1 + i) % #self.list + 1
			local val = self.list[valIndex]
			if val.name:sub(1, 1):lower() == key:lower() then
				self:SelectIndex(valIndex)
				return
			end
		end
	end
end
